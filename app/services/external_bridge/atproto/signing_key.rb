# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Instance confidential-client key. This is not a user vault secret and
    # is never written to user_external_credentials.
    class SigningKey
      ENV_CURRENT = 'ATPROTO_OAUTH_SIGNING_KEY'
      ENV_KID = 'ATPROTO_OAUTH_SIGNING_KID'
      ENV_PREVIOUS = 'ATPROTO_OAUTH_PREVIOUS_SIGNING_KEYS'

      Material = Struct.new(:kid, :key, :jwk, keyword_init: true)

      def self.current
        load_set[:current]
      end

      def self.for_kid(kid)
        load_set[:all][kid.to_s]
      end

      def self.public_jwks
        load_set[:all].values.map { |material| material.jwk.merge('use' => 'sig', 'alg' => 'ES256', 'kid' => material.kid) }
      end

      def self.configured?
        !current.nil?
      end

      def self.load_set
        current_pem = ENV[ENV_CURRENT].to_s
        return { current: nil, all: {} } if current_pem.blank?

        current_key = read_key(current_pem)
        current_jwk = Jwt.public_jwk(current_key)
        kid = ENV[ENV_KID].presence || Jwt.thumbprint(current_jwk)
        current = Material.new(kid: kid, key: current_key, jwk: current_jwk)
        all = previous_keys.merge(kid => current)
        { current: current, all: all }
      rescue OpenSSL::PKey::PKeyError, ArgumentError
        { current: nil, all: {} }
      end

      def self.previous_keys
        ENV[ENV_PREVIOUS].to_s.split(',').each_with_object({}) do |entry, keys|
          label, encoded = entry.split(':', 2)
          next if label.blank? || encoded.blank?

          key = read_key(Base64.strict_decode64(encoded))
          jwk = Jwt.public_jwk(key)
          keys[label] = Material.new(kid: label, key: key, jwk: jwk)
        end
      end

      def self.read_key(pem)
        normalized = pem.to_s.gsub('\n', "\n")
        key = OpenSSL::PKey::EC.new(normalized)
        raise ArgumentError, 'signing key must be a P-256 private key' unless key.private? && key.group.curve_name == 'prime256v1'

        key
      end

      private_class_method :load_set, :previous_keys, :read_key
    end
  end
end
