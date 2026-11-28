# frozen_string_literal: true

module WebUiDomains
  # One request's host classification. It does not change process-wide config.
  #
  # HTTP Origin is not read. access_origin is set only for a verified strict
  # entrance. P1 production code leaves the gate closed, so that origin stays
  # empty outside tests.
  class RequestContext
    LEGACY_ROLES = %i(web_domain local_domain alternate_domain).freeze

    attr_reader :canonical_origin, :access_origin, :observed_origin, :normalized_host,
                :host_roles, :mode, :failure_code, :forwarding_failure_code,
                :external_scheme, :external_port, :rails_effective_host,
                :rails_effective_scheme

    def self.build(request, configuration: nil, gate: Gate.closed, trusted_proxies: :application)
      Assembler.new(
        request: request,
        configuration: configuration || Rails.configuration.x.web_ui_domains,
        gate: gate,
        trusted_proxies: trusted_proxies
      ).assemble
    end

    def initialize(attrs)
      @canonical_origin = attrs.fetch(:canonical_origin)
      @access_origin = attrs.fetch(:access_origin)
      @observed_origin = attrs.fetch(:observed_origin)
      @normalized_host = attrs.fetch(:normalized_host)
      @host_roles = attrs.fetch(:host_roles)
      @mode = attrs.fetch(:mode)
      @failure_code = attrs.fetch(:failure_code)
      @forwarding_failure_code = attrs.fetch(:forwarding_failure_code)
      @forwarding_consistent = attrs.fetch(:forwarding_consistent)
      @configuration_rejected = attrs.fetch(:configuration_rejected)
      @external_scheme = attrs.fetch(:external_scheme)
      @external_port = attrs.fetch(:external_port)
      @rails_effective_host = attrs.fetch(:rails_effective_host)
      @rails_effective_scheme = attrs.fetch(:rails_effective_scheme)
      freeze
    end

    def strict_mode?
      mode == :strict
    end

    def forwarding_consistent?
      @forwarding_consistent
    end

    def configuration_rejected?
      @configuration_rejected
    end

    # Builds one context without retaining the request.
    class Assembler
      def initialize(request:, configuration:, gate:, trusted_proxies:)
        @request = request
        @configuration = configuration
        @gate = gate
        @trusted_proxies = trusted_proxies
      end

      def assemble
        authority = Authority.parse(@request.get_header('HTTP_HOST'))
        forwarding = forwarding_for(authority)
        roles = roles_for(authority)
        codes = blocking_codes(authority, forwarding, roles)
        mode = mode_for(authority, roles, codes)
        rails_host, rails_scheme = rails_observation
        RequestContext.new(
          canonical_origin: @configuration.canonical_origin,
          access_origin: mode == :strict ? origin_for(forwarding.scheme, authority) : nil,
          observed_origin: authority.ok? ? origin_for(forwarding.scheme, authority) : nil,
          normalized_host: authority.ok? ? authority.host : nil,
          host_roles: roles,
          mode: mode,
          failure_code: entrance_failure(roles, codes, mode),
          forwarding_failure_code: forwarding.failure_codes.first,
          forwarding_consistent: authority.ok? && forwarding.failure_codes.empty?,
          configuration_rejected: @configuration.rejected?,
          external_scheme: forwarding.scheme,
          external_port: authority.ok? ? authority.effective_port(forwarding.scheme) : nil,
          rails_effective_host: rails_host,
          rails_effective_scheme: rails_scheme
        )
      end

      private

      def forwarding_for(authority)
        return ForwardingAssessment::Result.new(scheme: nil, failure_codes: [:invalid_authority].freeze) unless authority.ok?

        ForwardingAssessment.assess(
          request: @request,
          authority: authority,
          peer_trusted: PeerTrust.trusted?(@request.get_header('REMOTE_ADDR'), @trusted_proxies)
        )
      end

      def roles_for(authority)
        return [].freeze unless authority.ok?

        @configuration.roles_for(authority.host)
      end

      def blocking_codes(authority, forwarding, roles)
        codes = forwarding.failure_codes.dup
        return codes unless authority.ok? && codes.empty? && roles.include?(:additional)

        codes << :scheme_not_https unless forwarding.scheme == 'https'
        codes << :port_not_https unless authority.effective_port(forwarding.scheme) == 443
        codes << :effective_authority_mismatch unless rails_matches?(authority, forwarding.scheme)
        codes
      end

      def mode_for(authority, roles, codes)
        return :rejected unless authority.ok?
        return :legacy if legacy?(roles)
        return additional_mode(codes) if roles.include?(:additional)

        :unrecognized
      end

      def additional_mode(codes)
        return :rejected if codes.any?
        return :strict if @gate.enabled?

        :additional_candidate
      end

      def legacy?(roles)
        roles.any? { |role| LEGACY_ROLES.include?(role) }
      end

      def entrance_failure(_roles, codes, mode)
        return unless mode == :rejected

        codes.first
      end

      def rails_matches?(authority, scheme)
        rails_host, rails_scheme, rails_port = rails_parts
        normalized = Hostname.normalize(rails_host.to_s)
        return false unless normalized.ok? && normalized.host == authority.host
        return false unless rails_scheme == scheme

        rails_port == authority.effective_port(scheme)
      end

      def rails_observation
        host, scheme, = rails_parts
        [host, scheme]
      end

      def rails_parts
        host = @request.host
        scheme = @request.ssl? ? 'https' : 'http'
        [host, scheme, @request.port]
      rescue StandardError
        [nil, nil, nil]
      end

      def origin_for(scheme, authority)
        return if scheme.nil? || authority.host.nil?

        port = authority.effective_port(scheme)
        default = scheme == 'https' ? 443 : 80
        suffix = port && port != default ? ":#{port}" : ''
        "#{scheme}://#{authority.host}#{suffix}"
      end
    end
  end
end
