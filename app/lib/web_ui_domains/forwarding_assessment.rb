# frozen_string_literal: true

module WebUiDomains
  # Forwarded headers are untrusted input. They never become the access origin
  # by themselves. A trusted proxy may confirm TLS termination with one
  # X-Forwarded-Proto value. RFC Forwarded is not parsed.
  class ForwardingAssessment
    Result = Struct.new(:scheme, :failure_codes, keyword_init: true)

    def self.assess(request:, authority:, peer_trusted:)
      new(request, authority, peer_trusted).assess
    end

    def initialize(request, authority, peer_trusted)
      @request = request
      @authority = authority
      @peer_trusted = peer_trusted
    end

    def assess
      scheme_code, scheme = scheme_decision
      codes = []
      codes << scheme_code if scheme_code
      host_code = host_decision(scheme)
      codes << host_code if host_code
      port_code = port_decision(scheme)
      codes << port_code if port_code
      codes << :forwarded_header_present if forwarded_header?
      Result.new(scheme: scheme, failure_codes: codes.freeze).freeze
    end

    private

    def scheme_decision
      code, forwarded = forwarded_scheme_token
      return [code, nil] if code

      connection = connection_scheme
      return [nil, connection] if forwarded.nil?
      return untrusted_scheme(connection, forwarded) unless @peer_trusted
      return [:scheme_downgrade, nil] if connection == 'https' && forwarded == 'http'

      [nil, forwarded]
    end

    def untrusted_scheme(connection, forwarded)
      return [:scheme_downgrade, nil] if connection == 'https' && forwarded == 'http'
      return [nil, connection] if forwarded == connection

      [:untrusted_forwarded_scheme, nil]
    end

    def forwarded_scheme_token
      protos = header_values('HTTP_X_FORWARDED_PROTO')
      return [:forwarded_proto_multiple, nil] if protos.length > 1

      proto = normalize_proto(protos.first)
      return [:forwarded_proto_invalid, nil] if protos.any? && proto.nil?

      ssl = header('HTTP_X_FORWARDED_SSL').to_s.strip.downcase
      return [:forwarded_ssl_invalid, nil] if ssl.present? && ssl != 'on'
      return [:forwarded_proto_invalid, nil] if proto && ssl == 'on' && proto != 'https'

      [nil, proto || (ssl == 'on' ? 'https' : nil)]
    end

    def normalize_proto(value)
      token = value.to_s.downcase
      token if %w(http https).include?(token)
    end

    def connection_scheme
      return 'https' if header('HTTPS').to_s == 'on'
      return 'https' if header('rack.url_scheme').to_s == 'https'

      'http'
    end

    def host_decision(scheme)
      values = header_values('HTTP_X_FORWARDED_HOST')
      return if values.empty?
      return :forwarded_host_multiple if values.length > 1

      forwarded = Authority.parse(values.first)
      return :forwarded_host_invalid unless forwarded.ok?
      return :forwarded_host_mismatch unless same_authority?(forwarded, scheme)

      nil
    end

    def same_authority?(forwarded, scheme)
      return false unless forwarded.host == @authority.host

      forwarded.effective_port(scheme) == @authority.effective_port(scheme)
    end

    def port_decision(scheme)
      values = header_values('HTTP_X_FORWARDED_PORT')
      return if values.empty?
      return :forwarded_port_multiple if values.length > 1

      port = integer_port(values.first)
      return :forwarded_port_invalid if port.nil?
      return :forwarded_port_mismatch if port != @authority.effective_port(scheme)

      nil
    end

    def integer_port(value)
      return unless value.match?(/\A\d+\z/)

      port = value.to_i
      port if port.between?(1, 65_535)
    end

    def forwarded_header?
      !header('HTTP_FORWARDED').to_s.strip.empty?
    end

    def header_values(name)
      text = header(name).to_s
      return [] if text.strip.empty?

      text.split(',').map(&:strip)
    end

    def header(name)
      @request.get_header(name)
    end
  end
end
