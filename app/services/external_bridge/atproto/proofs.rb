# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # One DPoP proof per request, and a private_key_jwt client assertion
    # whose audience is the bound issuer.
    class Proofs
      ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

      def self.dpop(key:, htm:, url:, nonce: nil)
        jwk = Jwt.public_jwk(key)
        header = { 'typ' => 'dpop+jwt', 'alg' => 'ES256', 'jwk' => jwk }
        claims = {
          'htm' => htm,
          'htu' => htu(url),
          'iat' => Time.now.to_i,
          'jti' => SecureRandom.uuid,
        }
        claims['nonce'] = nonce if nonce.present?
        Jwt.sign(header, claims, key)
      end

      def self.client_assertion(issuer:)
        material = SigningKey.current
        raise Error, :signing_key_unavailable if material.nil?

        now = Time.now.to_i
        header = { 'typ' => 'JWT', 'alg' => 'ES256', 'kid' => material.kid }
        claims = {
          'iss' => ClientDocument.client_id,
          'sub' => ClientDocument.client_id,
          'aud' => issuer,
          'iat' => now,
          'exp' => now + 60,
          'jti' => SecureRandom.uuid,
        }
        Jwt.sign(header, claims, material.key)
      end

      def self.client_assertion_for(material, issuer:)
        raise Error, :reauthentication_required if material.nil?

        now = Time.now.to_i
        header = { 'typ' => 'JWT', 'alg' => 'ES256', 'kid' => material.kid }
        claims = {
          'iss' => ClientDocument.client_id,
          'sub' => ClientDocument.client_id,
          'aud' => issuer,
          'iat' => now,
          'exp' => now + 60,
          'jti' => SecureRandom.uuid,
        }
        Jwt.sign(header, claims, material.key)
      end

      def self.htu(url)
        uri = Addressable::URI.parse(url)
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      end

      def self.pkce
        verifier = SecureRandom.urlsafe_base64(32)
        [verifier, Jwt.b64(Digest::SHA256.digest(verifier))]
      end

      def self.generate_dpop_key
        OpenSSL::PKey::EC.generate('prime256v1')
      end
    end
  end
end
