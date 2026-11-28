# frozen_string_literal: true

module WebUiDomains
  # Host header authority. The HTTP Origin header is not an input.
  class Authority
    Result = Struct.new(:host, :port, :error, keyword_init: true) do
      def ok?
        error.nil?
      end

      def effective_port(scheme)
        return port unless port.nil?
        return 443 if scheme == 'https'
        return 80 if scheme == 'http'

        nil
      end
    end

    def self.parse(raw)
      new(raw).parse
    end

    def initialize(raw)
      @raw = raw
    end

    def parse
      error = structural_error
      return failure(error) if error

      host_text, port = split_host_port
      return failure('has an invalid port') if port == :invalid

      normalized = Hostname.normalize(host_text)
      return failure(normalized.error) unless normalized.ok?

      Result.new(host: normalized.host, port: port, error: nil).freeze
    end

    private

    def structural_error
      return 'is missing' if @raw.nil?
      return 'is not a host authority' unless @raw.is_a?(String)
      return 'is missing' if @raw.empty?
      return 'contains multiple values' if @raw.include?(',')
      return 'contains whitespace or control characters' if @raw.match?(/[[:space:][:cntrl:]]/)
      return 'is an IP address' if @raw.start_with?('[')
      return 'contains a scheme, path, userinfo, or other non-authority character' if @raw.match?(%r{[@/?#\\*]})
      return 'is an IP address' if @raw.count(':') > 1

      nil
    end

    def split_host_port
      return [@raw, nil] unless @raw.include?(':')

      host, port_text = @raw.split(':', 2)
      return [host, :invalid] unless port_text.match?(/\A\d+\z/)

      port = port_text.to_i
      return [host, :invalid] unless port.between?(1, 65_535)

      [host, port]
    end

    def failure(message)
      Result.new(host: nil, port: nil, error: message).freeze
    end
  end
end
