# frozen_string_literal: true

require 'addressable/idna'
require 'ipaddr'

module WebUiDomains
  # One explicit DNS hostname. Comparison is the ASCII form, exact match.
  class Hostname
    Result = Struct.new(:host, :error, keyword_init: true) do
      def ok?
        error.nil?
      end
    end

    LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/.freeze
    MAX_LENGTH = 253
    STRUCTURAL = %r{[:/?#@\[\]\\*%!;=]}.freeze

    def self.normalize(value)
      new(value).normalize
    end

    # Host used only to compare LOCAL_DOMAIN, WEB_DOMAIN, and ALTERNATE_DOMAINS.
    # Those existing settings may include a port. WEB_UI_DOMAINS itself cannot.
    def self.comparable(value)
      text = value.to_s.strip
      return if text.empty?

      text = text.sub(%r{\A[a-z][a-z0-9+\-.]*://}i, '')
      text = text.split('/').first.to_s
      text = text.split('?').first.to_s
      text = text.split('#').first.to_s
      text = text.split('@').last.to_s
      text = strip_port(text)
      normalize(text).host || text.downcase
    end

    def self.strip_port(text)
      return text unless text.count(':') == 1 && !text.start_with?('[')

      host, port = text.split(':', 2)
      port.match?(/\A\d+\z/) ? host : text
    end
    private_class_method :strip_port

    def initialize(value)
      @value = value
    end

    def normalize
      error = structural_error
      return failure(error) if error

      ascii = ascii_host
      return failure('could not be converted to an ASCII hostname') if ascii.nil?

      error = dns_error(ascii)
      return failure(error) if error

      Result.new(host: ascii.freeze, error: nil).freeze
    end

    private

    def structural_error
      return 'is empty' if @value.nil? || (@value.is_a?(String) && @value.empty?)
      return 'is not a hostname string' unless @value.is_a?(String)
      return 'contains whitespace or control characters' if @value.match?(/[[:space:][:cntrl:]]/)
      return 'contains a scheme, port, path, wildcard, or other non-hostname character' if @value.match?(STRUCTURAL)
      return 'has a trailing dot or an empty label' if empty_label?(@value)

      nil
    end

    def ascii_host
      Addressable::IDNA.to_ascii(@value).downcase
    rescue StandardError
      nil
    end

    def dns_error(ascii)
      return 'has a trailing dot or an empty label' if empty_label?(ascii)
      return 'is longer than a DNS hostname' if ascii.length > MAX_LENGTH
      return 'is an IP address' if ip_literal?(ascii)
      return 'is not a valid DNS hostname' unless ascii.split('.').all? { |label| LABEL.match?(label) }

      nil
    end

    def empty_label?(text)
      text.start_with?('.') || text.end_with?('.') || text.include?('..')
    end

    def ip_literal?(ascii)
      IPAddr.new(ascii)
      true
    rescue IPAddr::Error
      labels = ascii.split('.')
      !labels.empty? && labels.all? { |label| label.match?(/\A(?:0x[0-9a-f]+|\d+)\z/) }
    end

    def failure(message)
      Result.new(host: nil, error: message).freeze
    end
  end
end
