# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public feed and item URLs. Userinfo and token-like queries are rejected
    # rather than stripped, so they never become a shared cache key.
    class CanonicalURL
      TOKEN_PARAMS = %w(token key sig signature access_token).freeze

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

        params = uri.query.split('&').map { |pair| pair.split('=', 2).first.to_s }
        raise Error, :authenticated_source_rejected if params.any? { |name| TOKEN_PARAMS.include?(name.downcase) }
      end
    end
  end
end
