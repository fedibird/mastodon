# frozen_string_literal: true

# Extracts a destination domain from an imported acct string without keeping
# the username. Bare (local) addresses default to the local domain, matching
# FollowImportTarget.key_hash, then reuse TagManager normalization.
module FollowImport
  module DestinationDomain
    module_function

    def from_acct(acct)
      username, domain = acct.to_s.strip.split('@', 2)
      return if username.blank?

      domain = Rails.configuration.x.local_domain if domain.blank?
      TagManager.instance.normalize_domain(domain.to_s)
    rescue StandardError
      domain.to_s.downcase.presence
    end
  end
end
