# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Resolves a URL and rejects private, loopback, and reserved answers
    # before Request opens a socket. Request checks again at connect time.
    class Destination
      def self.check!(url, dns:)
        new(url, dns).check!
      end

      def initialize(url, dns)
        @url = url.to_s
        @dns = dns
      end

      def check!
        uri = Addressable::URI.parse(@url)
        raise Error, :discovery_rejected if uri.nil? || uri.scheme&.downcase != 'https'
        raise Error, :discovery_rejected if uri.host.blank? || uri.user.present? || uri.password.present?

        host = uri.normalized_host.to_s
        raise Error, :private_address if Origin.blocked_host?(host)

        assert_public!(host)
        uri.to_s
      rescue Addressable::URI::InvalidURIError
        raise Error, :discovery_rejected
      end

      private

      def assert_public!(host)
        addresses = public_answers(host)
        raise Error, :discovery_rejected if addresses.empty?

        addresses.each do |ip|
          raise Error, :private_address if PrivateAddressCheck.private_address?(ip)
        end
      end

      def public_answers(host)
        return [IPAddr.new(host)] if literal?(host)

        Array(@dns.addresses(host)).map { |address| address.is_a?(IPAddr) ? address : IPAddr.new(address.to_s) }
      rescue IPAddr::InvalidAddressError
        raise Error, :discovery_rejected
      end

      def literal?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
