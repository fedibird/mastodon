# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # HTTPS origins only. A handle, DID, or hostname is never a token URL.
    class Origin
      def self.https_origin!(value)
        new(value).https_origin!
      end

      def self.of(value)
        https_origin!(value)
      rescue Error
        nil
      end

      # Origin of an https URL that is allowed to have a path, such as a
      # token or PAR endpoint. The path is not returned.
      def self.endpoint_origin(value)
        uri = Addressable::URI.parse(value.to_s)
        return nil if uri.nil? || uri.scheme&.downcase != 'https'
        return nil if uri.host.blank? || uri.user.present? || uri.password.present? || uri.fragment.present?

        host = uri.normalized_host.to_s
        return nil if host.blank? || blocked_host?(host)

        port = uri.port
        origin = "https://#{host}"
        origin = "#{origin}:#{port}" if port && port != 443
        origin
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def initialize(value)
        @value = value.to_s
      end

      def https_origin!
        uri = parse!
        raise Error, :discovery_rejected unless uri.path.blank? || uri.path == '/'
        raise Error, :discovery_rejected if uri.query.present? || uri.fragment.present?

        host = uri.normalized_host.to_s
        raise Error, :discovery_rejected if host.blank? || explicit_default_port?
        raise Error, :private_address if self.class.blocked_host?(host)

        port = uri.port
        origin = "https://#{host}"
        origin = "#{origin}:#{port}" if port && port != 443
        origin
      end

      def self.blocked_host?(host)
        name = host.to_s.downcase
        return true if name.blank? || name == 'localhost' || name.end_with?('.localhost', '.local', '.onion', '.i2p')
        return true if ['metadata.google.internal', '0.0.0.0'].include?(name)

        literal = IPAddr.new(name)
        PrivateAddressCheck.private_address?(literal)
      rescue IPAddr::InvalidAddressError
        false
      end

      private

      def parse!
        uri = Addressable::URI.parse(@value.strip)
        raise Error, :discovery_rejected if uri.nil? || uri.scheme&.downcase != 'https'
        raise Error, :discovery_rejected if uri.host.blank? || uri.user.present? || uri.password.present?

        uri
      rescue Addressable::URI::InvalidURIError
        raise Error, :discovery_rejected
      end

      def explicit_default_port?
        authority = @value.strip[/\Ahttps:\/\/([^\/?#]+)/i, 1].to_s
        authority.end_with?(':443')
      end
    end
  end
end
