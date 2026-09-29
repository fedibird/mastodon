# frozen_string_literal: true

module UserCredentialVault
  # Dedicated keyring. This class does not read SECRET_KEY_BASE, OTP_SECRET,
  # VAPID keys, or provider API keys, and it does not fall back to them.
  #
  # USER_EXTERNAL_CREDENTIAL_KEYS=v2:<base64>,v1:<base64>
  # USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY=v2
  #
  # Each value is standard Base64 (with padding) of exactly 32 random bytes.
  # Duplicate ids, malformed Base64, the wrong decoded length, and a primary
  # id that is not in the ring fail closed. Missing configuration also fails
  # closed, but only when the vault is used. Loading this class does not
  # require the variables, so Mastodon can boot before a consumer exists.
  #
  # Operator rotation:
  # 1. Add the new key beside the old key.
  # 2. Point USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY at the new id.
  # 3. Deploy. New writes use the new key. Old rows still decrypt.
  # 4. Run `rake user_external_credentials:rotate` (preview with DRY_RUN=1).
  # 5. Confirm no row still uses the old id (`rake user_external_credentials:key_counts`).
  # 6. Remove the old key in a later deploy.
  class Keyring
    KEY_PATTERN = /\A[A-Za-z0-9+\/]+={0,2}\z/

    class << self
      def configured?
        ENV['USER_EXTERNAL_CREDENTIAL_KEYS'].present? || ENV['USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY'].present?
      end

      def load!
        new(ENV['USER_EXTERNAL_CREDENTIAL_KEYS'], ENV['USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY']).tap(&:validate!)
      end
    end

    attr_reader :primary_id

    def initialize(serialized_keys, primary_id)
      @serialized_keys = serialized_keys
      @primary_id = primary_id
      @keys = nil
    end

    def validate!
      return self if @keys

      raise ConfigurationError, 'user external credential keyring is not configured' if @serialized_keys.blank?
      raise ConfigurationError, 'user external credential primary key is not configured' if @primary_id.blank?

      @keys = parse_keys(@serialized_keys)
      raise ConfigurationError, 'user external credential primary key is malformed' unless @primary_id.match?(UserExternalCredential::KEY_ID_FORMAT)
      raise ConfigurationError, 'user external credential primary key is not in the keyring' unless @keys.key?(@primary_id)

      self
    end

    def key_for!(key_id)
      validate!
      raise UnknownKey, 'unknown encryption key id' unless @keys.key?(key_id)

      @keys.fetch(key_id)
    end

    def primary_key
      key_for!(primary_id)
    end

    def inspect
      ids = @keys&.keys
      "#<#{self.class.name} primary_id=#{@primary_id.inspect} key_ids=#{ids.inspect}>"
    end
    alias pretty_inspect inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    private

    def parse_keys(serialized)
      raise ConfigurationError, 'user external credential keyring is malformed' if serialized.match?(/\s/)

      keys = {}
      serialized.split(',').each do |entry|
        id, encoded = entry.split(':', 2)
        raise ConfigurationError, 'user external credential keyring is malformed' if id.blank? || encoded.blank?
        raise ConfigurationError, 'user external credential keyring is malformed' unless id.match?(UserExternalCredential::KEY_ID_FORMAT)
        raise ConfigurationError, "duplicate user external credential key id #{id}" if keys.key?(id)

        keys[id] = decode_key(encoded)
      end
      raise ConfigurationError, 'user external credential keyring is malformed' if keys.empty?

      keys
    end

    def decode_key(encoded)
      raise ConfigurationError, 'user external credential keyring is malformed' unless encoded.match?(KEY_PATTERN)

      decoded = Base64.strict_decode64(encoded)
      raise ConfigurationError, 'user external credential key must be 32 bytes' unless decoded.bytesize == Cipher::KEY_LENGTH

      decoded
    rescue ArgumentError
      raise ConfigurationError, 'user external credential keyring is malformed'
    end
  end
end
