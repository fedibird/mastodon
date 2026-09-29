# frozen_string_literal: true

module UserCredentialVault
  # Authenticated purpose passed to ActiveSupport::MessageEncryptor.
  #
  # For aes-256-gcm, MessageEncryptor seals this string inside the encrypted
  # metadata (ActiveSupport::Messages::Metadata). The AES-GCM tag covers it.
  # It is not a cleartext header. decrypt_and_verify returns nil when the
  # purpose built from the row being read differs from the purpose sealed at
  # encryption time; the vault treats that as authentication failure.
  #
  # Exact encoding, ASCII:
  #   user_external_credential:v1
  #   then the fields below, separated by ASCII 0x1E, in this order:
  #     payload_schema, binding_id, user_id, provider, purpose, credential_type
  #   each field is:
  #     <name> 0x1F <decimal UTF-8 byte length, no leading zeros> 0x1F <value>
  #
  # Length prefixes keep the encoding unambiguous if a value ever contains
  # ":" or another field's text. 0x1E and 0x1F are rejected inside values.
  # Changing a bound column without decrypting and re-encrypting under the
  # new context cannot produce a usable credential.
  class Context
    PREFIX = 'user_external_credential:v1'
    RECORD_SEPARATOR = "\x1e"
    UNIT_SEPARATOR = "\x1f"
    FIELDS = %w(payload_schema binding_id user_id provider purpose credential_type).freeze

    class << self
      # rubocop:disable Metrics/ParameterLists -- every bound field has to be named at the call site
      def build(payload_schema:, binding_id:, user_id:, provider:, purpose:, credential_type:)
        values = {
          'payload_schema' => canonical_integer(payload_schema),
          'binding_id' => canonical_token(binding_id),
          'user_id' => canonical_integer(user_id),
          'provider' => canonical_token(provider),
          'purpose' => canonical_token(purpose),
          'credential_type' => canonical_token(credential_type),
        }
        ([PREFIX] + FIELDS.map { |name| encode_field(name, values.fetch(name)) }).join(RECORD_SEPARATOR)
      end
      # rubocop:enable Metrics/ParameterLists

      private

      def encode_field(name, value)
        "#{name}#{UNIT_SEPARATOR}#{value.bytesize}#{UNIT_SEPARATOR}#{value}"
      end

      def canonical_integer(value)
        number = Integer(value)
        raise IntegrityError, 'credential context is invalid' if number.negative?

        number.to_s
      rescue ArgumentError, TypeError
        raise IntegrityError, 'credential context is invalid'
      end

      def canonical_token(value)
        string = value.to_s
        if string.empty? || string.include?(RECORD_SEPARATOR) || string.include?(UNIT_SEPARATOR)
          raise IntegrityError, 'credential context is invalid'
        end

        string
      end
    end
  end
end
