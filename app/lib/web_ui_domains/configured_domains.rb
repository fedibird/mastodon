# frozen_string_literal: true

module WebUiDomains
  # Snapshot of the existing domain settings. WEB_UI_DOMAINS is not one of them.
  class ConfiguredDomains
    attr_reader :local_domain, :web_domain, :alternate_domains, :use_https

    def initialize(local_domain:, web_domain:, alternate_domains:, use_https:)
      @local_domain = local_domain
      @web_domain = web_domain
      @alternate_domains = Array(alternate_domains).dup.freeze
      @use_https = use_https
      freeze
    end
  end
end
