# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # ES256 compact JWTs. Signatures are JOSE R||S, not ASN.1 DER.
    class Jwt
      def self.sign(header, claims, key)
        encoded = "#{json_b64(header)}.#{json_b64(claims)}"
        "#{encoded}.#{b64(raw_signature(key, encoded))}"
      end

      def self.b64(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end

      def self.json_b64(value)
        b64(JSON.generate(value))
      end

      def self.public_jwk(key)
        octet = key.public_key.to_octet_string(:uncompressed)
        x = b64(octet.byteslice(1, 32))
        y = b64(octet.byteslice(33, 32))
        {
          'crv' => 'P-256',
          'kty' => 'EC',
          'x' => x,
          'y' => y,
        }
      end

      def self.thumbprint(jwk)
        canonical = JSON.generate('crv' => jwk.fetch('crv'), 'kty' => jwk.fetch('kty'), 'x' => jwk.fetch('x'), 'y' => jwk.fetch('y'))
        b64(Digest::SHA256.digest(canonical))
      end

      def self.raw_signature(key, data)
        der = key.sign(OpenSSL::Digest.new('SHA256'), data)
        asn = OpenSSL::ASN1.decode(der)
        [asn.value[0].value, asn.value[1].value].map { |number| left_pad(number.to_s(2)) }.join
      end

      def self.left_pad(bytes)
        padded = bytes.bytesize > 32 ? bytes.byteslice(-32, 32) : bytes
        padded.rjust(32, "\x00".b)
      end
    end
  end
end
