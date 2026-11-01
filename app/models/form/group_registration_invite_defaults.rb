# frozen_string_literal: true

class Form::GroupRegistrationInviteDefaults
  include ActiveModel::Model

  attr_accessor :issuance_enabled, :shared_registration_quota, :shared_quota_unlimited,
                :per_link_max_uses, :per_link_unlimited_uses,
                :per_link_lifetime_seconds, :per_link_indefinite, :fingerprint

  def self.from_settings
    snapshot = GroupRegistrationInvites::SiteDefaults.snapshot
    new(
      issuance_enabled: snapshot[:issuance_enabled],
      shared_registration_quota: Setting.group_registration_invites_shared_quota,
      shared_quota_unlimited: snapshot[:shared_quota_unlimited],
      per_link_max_uses: Setting.group_registration_invites_per_link_max_uses,
      per_link_unlimited_uses: snapshot[:per_link_unlimited_uses],
      per_link_lifetime_seconds: Setting.group_registration_invites_per_link_lifetime_seconds,
      per_link_indefinite: snapshot[:per_link_indefinite],
      fingerprint: GroupRegistrationInvites::UpdateSiteDefaults.fingerprint
    )
  end

  def self.from_submission(attributes)
    values = attributes.to_h.with_indifferent_access
    new(
      issuance_enabled: GroupRegistrationInvites::Attributes.boolean(values[:issuance_enabled]),
      shared_quota_unlimited: GroupRegistrationInvites::Attributes.boolean(values[:shared_quota_unlimited]),
      per_link_unlimited_uses: GroupRegistrationInvites::Attributes.boolean(values[:per_link_unlimited_uses]),
      per_link_indefinite: GroupRegistrationInvites::Attributes.boolean(values[:per_link_indefinite]),
      shared_registration_quota: values[:shared_registration_quota],
      per_link_max_uses: values[:per_link_max_uses],
      per_link_lifetime_seconds: values[:per_link_lifetime_seconds],
      fingerprint: GroupRegistrationInvites::UpdateSiteDefaults.fingerprint
    )
  end
end
