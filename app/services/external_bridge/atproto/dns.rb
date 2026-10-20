# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Live DNS for discovery. Tests pass their own resolver. Failures do not
    # fall through to a token request.
    class Dns
      def self.live
        @live ||= Live.new
      end

      class Live
        def addresses(host)
          Resolv::DNS.open do |dns|
            dns.timeouts = 5
            dns.getaddresses(host).map { |address| IPAddr.new(address.to_s) }
          end
        rescue Resolv::ResolvError, Resolv::ResolvTimeout, IPAddr::InvalidAddressError
          raise Error, :discovery_rejected
        end

        def txt(name)
          Resolv::DNS.open do |dns|
            dns.timeouts = 5
            dns.getresources(name, Resolv::DNS::Resource::IN::TXT).map { |record| record.strings.join }
          end
        rescue Resolv::ResolvError, Resolv::ResolvTimeout
          raise Error, :discovery_rejected
        end
      end
    end
  end
end
