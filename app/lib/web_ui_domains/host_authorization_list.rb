# frozen_string_literal: true

module WebUiDomains
  # Names copied into config.hosts. Additional WebUI hosts are not a parameter.
  class HostAuthorizationList
    def self.legacy(local_domain:, web_domain:, alternate_domains:)
      names = []
      names << local_domain if local_domain.present?
      names << web_domain if web_domain.present?
      names.concat(alternate_domains) if alternate_domains.present?
      names
    end
  end
end
