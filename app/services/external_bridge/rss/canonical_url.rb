# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public feed and item URLs. Userinfo and credential-like queries are
    # rejected rather than stripped, so they never become a shared cache key.
    class CanonicalURL
      # Compared after percent-decoding and removing non-alphanumerics.
      SENSITIVE_NAMES = %w(
        token accesstoken refreshtoken idtoken
        key apikey appkey privatekey
        sig signature
        password passwd pwd
        auth authorization
        secret clientsecret
        credential credentials
        session sessionid sid
        jwt bearer
        oauth oauthtoken
      ).freeze

      def self.normalize!(value)
        new(value).normalize!
      end

      def self.safe_http?(value)
        normalize!(value)
        true
      rescue ExternalBridge::Error
        false
      end

      def initialize(value)
        @value = value.to_s
      end

      def normalize!
        uri = parse!
        reject_userinfo!(uri)
        reject_token_query!(uri)
        reject_private_literal!(uri)
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = nil if uri.port == uri.default_port
        uri.fragment = nil
        uri.path = '' if uri.path == '/'
        key = uri.to_s
        raise Error, :unsupported_url if key.bytesize > Limits::MAX_KEY_BYTES

        key
      end

      private

      def parse!
        uri = Addressable::URI.parse(@value)
        raise Error, :unsupported_url if uri.nil?
        raise Error, :unsupported_url unless %w(http https).include?(uri.scheme&.downcase)
        raise Error, :unsupported_url if uri.host.blank?

        uri
      rescue Addressable::URI::InvalidURIError
        raise Error, :unsupported_url
      end

      def reject_userinfo!(uri)
        raise Error, :authenticated_source_rejected if uri.user.present? || uri.password.present?
      end

      def reject_private_literal!(uri)
        address = IPAddr.new(uri.host)
        raise Error, :private_address if PrivateAddressCheck.private_address?(address)
      rescue IPAddr::InvalidAddressError
        nil
      end

      def reject_token_query!(uri)
        return if uri.query.blank?
        raise Error, :authenticated_source_rejected if malformed_percent?(uri.query)
        raise Error, :authenticated_source_rejected if query_names(uri.query).any? { |name| sensitive_name?(name) }
      end

      def malformed_percent?(query)
        query.match?(/%(?![0-9A-Fa-f]{2})/)
      end

      def query_names(query)
        query.split(/[&;]/).map { |pair| pair.split('=', 2).first.to_s }
      end

      def sensitive_name?(raw)
        candidate = raw
        3.times do
          decoded = decode_component(candidate)
          return true if decoded.nil?
          return true if sensitive_token?(decoded)

          break if decoded == candidate

          candidate = decoded
        end
        false
      end

      def decode_component(value)
        Addressable::URI.unencode_component(value.to_s.tr('+', ' '))
      rescue ArgumentError, Addressable::URI::InvalidURIError
        nil
      end

      def sensitive_token?(name)
        folded = name.to_s.downcase
        candidates = [folded, folded.gsub(/\[\d*\]\z/, '')]
        candidates.any? { |candidate| SENSITIVE_NAMES.include?(candidate.gsub(/[^a-z0-9]/, '')) }
      end
    end
  end
end
