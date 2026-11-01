# frozen_string_literal: true

module GroupRegistrationInvites
  # Reads the site defaults at the moment of approval. The returned hash is
  # copied onto one GroupRegistrationInvitePolicy. Nothing here writes back
  # to existing policies.
  module SiteDefaults
    module_function

    def snapshot
      {
        issuance_enabled: boolean(Setting.group_registration_invites_enabled),
        shared_registration_quota: integer(Setting.group_registration_invites_shared_quota),
        shared_quota_unlimited: boolean(Setting.group_registration_invites_shared_quota_unlimited),
        per_link_max_uses: unlimited_uses? ? nil : integer(Setting.group_registration_invites_per_link_max_uses),
        per_link_unlimited_uses: unlimited_uses?,
        per_link_lifetime_seconds: indefinite? ? nil : integer(Setting.group_registration_invites_per_link_lifetime_seconds),
        per_link_indefinite: indefinite?,
      }
    end

    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def integer(value)
      Integer(value)
    rescue ArgumentError, TypeError
      0
    end

    def unlimited_uses?
      boolean(Setting.group_registration_invites_per_link_unlimited_uses)
    end

    def indefinite?
      boolean(Setting.group_registration_invites_per_link_indefinite)
    end
  end
end
