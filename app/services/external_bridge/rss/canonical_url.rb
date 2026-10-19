# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public feed and item URLs. Query strings are fail-closed: the only
    # stored form is a known-safe format parameter. Unknown names, credential
    # aliases, and percent-encoding that does not resolve are rejected before
    # HTTP and before a shared row is written.
    class CanonicalURL
      SAFE_QUERY_NAMES = %w(format).freeze
      SAFE_FORMAT_VALUES = %w(rss atom xml feed).freeze
      MAX_DECODE = 8

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
        reject_query!(uri)
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

      def reject_query!(uri)
        return if uri.query.nil?
        raise Error, :authenticated_source_rejected if uri.query.blank? || malformed_percent?(uri.query)

        pairs = uri.query.split(/[&;]/)
        raise Error, :authenticated_source_rejected unless pairs.one?

        name, value = pairs.first.split('=', 2)
        raise Error, :authenticated_source_rejected if value.nil?

        decoded_name = fully_decode(name)
        decoded_value = fully_decode(value)
        raise Error, :authenticated_source_rejected if decoded_name.blank? || decoded_value.blank?
        raise Error, :authenticated_source_rejected unless SAFE_QUERY_NAMES.include?(decoded_name.downcase)
        raise Error, :authenticated_source_rejected unless SAFE_FORMAT_VALUES.include?(decoded_value.downcase)

        uri.query = "#{decoded_name.downcase}=#{decoded_value.downcase}"
      end

      def fully_decode(raw)
        candidate = raw.to_s
        MAX_DECODE.times do
          return nil if malformed_percent?(candidate)

          decoded = decode_component(candidate)
          return nil if decoded.nil?
          return candidate if decoded == candidate

          candidate = decoded
        end
        return nil if candidate.include?('%') || malformed_percent?(candidate)

        candidate
      end

      def malformed_percent?(text)
        text.to_s.match?(%r{%(?![0-9A-Fa-f]{2})})
      end

      def decode_component(value)
        Addressable::URI.unencode_component(value.to_s.tr('+', ' '))
      rescue ArgumentError, Addressable::URI::InvalidURIError
        nil
      end
    end
  end
end
