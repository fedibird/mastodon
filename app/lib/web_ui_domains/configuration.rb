# frozen_string_literal: true

require 'public_suffix'

module WebUiDomains
  # Immutable parse of WEB_UI_DOMAINS. A rejected list adopts no hosts.
  class Configuration
    Token = Struct.new(:token, :host, keyword_init: true)

    attr_reader :additional_hosts, :alternate_hosts, :errors, :rp_id,
                :canonical_origin, :web_host, :local_host

    def self.load!(raw, domains:)
      configuration = parse(raw, domains: domains)
      return configuration unless configuration.rejected?

      raise ConfigurationError, configuration.error_message
    end

    def self.parse(raw, domains:)
      return invalid_type(domains) unless raw.nil? || raw.is_a?(String)
      return accept(domains, []) if raw.nil? || raw.strip.empty?

      tokens = raw.split(',').map(&:strip).reject(&:empty?)
      return accept(domains, []) if tokens.empty?

      normalized, token_errors = normalize_tokens(tokens)
      return reject(domains, token_errors) if token_errors.any?

      list_errors = consistency_errors(normalized, domains)
      return reject(domains, list_errors) if list_errors.any?

      accept(domains, normalized.map(&:host))
    end

    def self.normalize_tokens(tokens)
      errors = []
      normalized = tokens.map do |token|
        result = Hostname.normalize(token)
        if result.ok?
          Token.new(token: token, host: result.host)
        else
          errors << "#{token.inspect}: #{result.error}"
          nil
        end
      end
      [normalized.compact, errors]
    end
    private_class_method :normalize_tokens

    def self.consistency_errors(normalized, domains)
      duplicate_errors(normalized) + collision_errors(normalized, domains) + subdomain_errors(normalized, domains)
    end
    private_class_method :consistency_errors

    def self.duplicate_errors(normalized)
      normalized.group_by(&:host).each_with_object([]) do |(host, rows), errors|
        next if rows.length < 2

        shown = rows.map { |row| row.token.inspect }.join(', ')
        errors << "#{shown} normalize to the same host #{host}"
      end
    end
    private_class_method :duplicate_errors

    def self.collision_errors(normalized, domains)
      reserved = reserved_hosts(domains)
      normalized.each_with_object([]) do |row, errors|
        next unless reserved.include?(row.host)

        errors << "#{row.token.inspect}: collides with LOCAL_DOMAIN, WEB_DOMAIN, or ALTERNATE_DOMAINS"
      end
    end
    private_class_method :collision_errors

    def self.subdomain_errors(normalized, domains)
      rp_id = Hostname.comparable(domains.web_domain)
      normalized.each_with_object([]) do |row, errors|
        reason = subdomain_failure(row.host, rp_id)
        errors << "#{row.token.inspect}: #{reason}" if reason
      end
    end
    private_class_method :subdomain_errors

    def self.subdomain_failure(host, rp_id)
      return 'has no WebAuthn RP ID to compare' if rp_id.blank?
      return "is not a DNS subdomain of the WebAuthn RP ID #{rp_id}" unless dns_subdomain?(host, rp_id)
      return "cannot be used because the WebAuthn RP ID #{rp_id} is a public suffix" if public_suffix_name?(rp_id)

      registrable_failure(host, rp_id)
    end
    private_class_method :subdomain_failure

    def self.registrable_failure(host, rp_id)
      rp_domain = registrable_domain(rp_id)
      host_domain = registrable_domain(host)
      return if rp_domain && host_domain == rp_domain && registrable_parent?(rp_id, rp_domain)

      "is not in the same registrable domain as the WebAuthn RP ID #{rp_id}"
    end
    private_class_method :registrable_failure

    def self.dns_subdomain?(host, rp_id)
      host != rp_id && host.end_with?(".#{rp_id}")
    end
    private_class_method :dns_subdomain?

    def self.registrable_parent?(rp_id, rp_domain)
      rp_id == rp_domain || rp_id.end_with?(".#{rp_domain}")
    end
    private_class_method :registrable_parent?

    def self.public_suffix_name?(name)
      PublicSuffix.parse(name)
      false
    rescue PublicSuffix::DomainNotAllowed
      true
    rescue PublicSuffix::Error
      true
    end
    private_class_method :public_suffix_name?

    def self.registrable_domain(name)
      PublicSuffix.domain(name)
    rescue PublicSuffix::Error
      nil
    end
    private_class_method :registrable_domain

    def self.reserved_hosts(domains)
      hosts = [Hostname.comparable(domains.local_domain), Hostname.comparable(domains.web_domain)]
      domains.alternate_domains.each { |name| hosts << Hostname.comparable(name) }
      hosts.compact
    end
    private_class_method :reserved_hosts

    def self.accept(domains, hosts)
      new(domains: domains, additional_hosts: hosts, errors: [])
    end
    private_class_method :accept

    def self.reject(domains, errors)
      new(domains: domains, additional_hosts: [], errors: errors)
    end
    private_class_method :reject

    def self.invalid_type(domains)
      reject(domains, ['WEB_UI_DOMAINS must be a comma-separated string'])
    end
    private_class_method :invalid_type

    def initialize(domains:, additional_hosts:, errors:)
      @additional_hosts = additional_hosts.map(&:freeze).freeze
      @errors = errors.map(&:freeze).freeze
      @web_host = Hostname.comparable(domains.web_domain)&.freeze
      @local_host = Hostname.comparable(domains.local_domain)&.freeze
      @alternate_hosts = domains.alternate_domains.filter_map { |name| Hostname.comparable(name)&.freeze }.freeze
      @rp_id = @web_host
      @canonical_origin = canonical_origin_for(domains).freeze
      freeze
    end

    def rejected?
      errors.any?
    end

    # Production never enables strict mode from this object.
    def strict_mode_enabled?
      false
    end

    def roles_for(host)
      roles = []
      roles << :web_domain if host == web_host
      roles << :local_domain if host == local_host
      roles << :alternate_domain if alternate_hosts.include?(host)
      roles << :additional if additional_hosts.include?(host)
      roles.freeze
    end

    def error_message
      return if errors.empty?

      lines = errors.map { |error| "- #{error}" }
      "WEB_UI_DOMAINS was rejected as a whole; no host was adopted.\n#{lines.join("\n")}"
    end

    private

    def canonical_origin_for(domains)
      scheme = domains.use_https ? 'https' : 'http'
      "#{scheme}://#{domains.web_domain}"
    end
  end
end
