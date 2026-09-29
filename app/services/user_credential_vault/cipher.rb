# frozen_string_literal: true

module UserCredentialVault
  # AES-256-GCM through ActiveSupport::MessageEncryptor.
  #
  # aes-256-gcm is an AEAD cipher. MessageEncryptor therefore does not apply
  # a separate HMAC; the GCM tag authenticates the encrypted metadata, and
  # that metadata contains the purpose string from Context. Do not switch
  # this to aes-256-cbc or to Marshal. attr_encrypted is not used.
  class Cipher
    CIPHER_NAME = 'aes-256-gcm'
    KEY_LENGTH = ActiveSupport::MessageEncryptor.key_len(CIPHER_NAME)

    module JsonSerializer
      def self.dump(value)
        JSON.generate(value)
      end

      def self.load(value)
        parsed = JSON.parse(value)
        raise MalformedPayload, 'credential payload is malformed' unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise MalformedPayload, 'credential payload is malformed'
      end
    end

    class << self
      def encrypt(payload, key:, purpose:)
        encryptor(key).encrypt_and_sign(payload, purpose: purpose)
      end

      def decrypt(ciphertext, key:, purpose:)
        raw = encryptor(key).decrypt_and_verify(ciphertext, purpose: purpose)
        raise AuthenticationFailure, 'credential authentication failed' if raw.nil?

        raw
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise AuthenticationFailure, 'credential authentication failed'
      end

      private

      def encryptor(key)
        raise ConfigurationError, 'user external credential key must be 32 bytes' unless key.is_a?(String) && key.bytesize == KEY_LENGTH

        ActiveSupport::MessageEncryptor.new(key, cipher: CIPHER_NAME, serializer: JsonSerializer)
      end
    end
  end
end
