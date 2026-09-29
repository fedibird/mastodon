# frozen_string_literal: true

module UserCredentialVault
  # Versioned JSON document sealed inside the ciphertext.
  #
  # Shape:
  #   { "version": 1, "credentials": { "api_key": "..." } }
  #
  # JSON.generate / JSON.parse only. This path never uses Marshal, Oj, or any
  # loader that constructs arbitrary classes.
  class Payload
    VERSION = 1
    MAX_FIELDS = 16
    MAX_VALUE_BYTES = 8_192
    MAX_JSON_BYTES = 16_384
    ALLOWED_KEYS = %w(version credentials).freeze

    class << self
      def wrap(credentials)
        payload = {
          'version' => VERSION,
          'credentials' => normalize(credentials),
        }
        raise ArgumentError, 'credential payload is too large' if JSON.generate(payload).bytesize > MAX_JSON_BYTES

        payload
      end

      def unwrap(payload)
        raise MalformedPayload, 'credential payload is malformed' unless payload.is_a?(Hash)
        raise MalformedPayload, 'credential payload is malformed' unless payload.keys.map(&:to_s).sort == ALLOWED_KEYS.sort
        raise MalformedPayload, 'credential payload is malformed' unless payload['version'] == VERSION

        normalize(payload['credentials'])
        payload
      rescue ArgumentError
        raise MalformedPayload, 'credential payload is malformed'
      end

      private

      def normalize(credentials)
        raise ArgumentError, 'credentials must be a hash of strings' unless credentials.is_a?(Hash)
        raise ArgumentError, 'credentials must not be empty' if credentials.empty?
        raise ArgumentError, 'credentials has too many fields' if credentials.size > MAX_FIELDS

        credentials.each_with_object({}) do |(key, value), normalized|
          name = key.is_a?(Symbol) ? key.to_s : key
          raise ArgumentError, 'credential field name is invalid' unless name.is_a?(String) && name.match?(UserExternalCredential::IDENTIFIER_FORMAT)
          raise ArgumentError, 'credential field name is invalid' if normalized.key?(name)

          normalized[name] = normalize_value(value)
        end
      end

      def normalize_value(value)
        raise ArgumentError, 'credential values must be strings' unless value.is_a?(String)

        string = value.dup
        string.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::ASCII_8BIT
        raise ArgumentError, 'credential values must be valid UTF-8' unless string.encoding == Encoding::UTF_8 && string.valid_encoding?
        raise ArgumentError, 'credential values must not be empty' if string.empty?
        raise ArgumentError, 'credential value is too large' if string.bytesize > MAX_VALUE_BYTES

        string
      end
    end
  end
end
