# frozen_string_literal: true

require 'ipaddr'

module WebUiDomains
  # Whether the immediate TCP peer is a trusted proxy.
  #
  # This is REMOTE_ADDR. It is not request.remote_ip and not an address taken
  # from X-Forwarded-For.
  class PeerTrust
    def self.trusted?(remote_addr, trusted_proxies)
      new(remote_addr, trusted_proxies).trusted?
    end

    def initialize(remote_addr, trusted_proxies)
      @remote_addr = remote_addr.to_s
      @trusted_proxies = trusted_proxies
    end

    def trusted?
      return false if @remote_addr.empty?

      case @trusted_proxies
      when :application
        application_trusted?
      when :none
        false
      else
        listed?(@trusted_proxies)
      end
    end

    private

    def application_trusted?
      proxies = Rails.application.config.action_dispatch.trusted_proxies
      return listed?(proxies) unless proxies.nil?

      !Rack::Request.ip_filter.call(@remote_addr).nil?
    end

    def listed?(proxies)
      Array(proxies).any? { |proxy| matches_proxy?(proxy) }
    end

    def matches_proxy?(proxy)
      return proxy.include?(@remote_addr) if proxy.is_a?(IPAddr)

      proxy.to_s == @remote_addr
    rescue IPAddr::Error
      false
    end
  end
end
