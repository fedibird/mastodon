# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupRegistrationInvites::UpdateSiteDefaults do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = {
      enabled: Setting.group_registration_invites_enabled,
      quota: Setting.group_registration_invites_shared_quota,
      quota_unlimited: Setting.group_registration_invites_shared_quota_unlimited,
      max_uses: Setting.group_registration_invites_per_link_max_uses,
      unlimited_uses: Setting.group_registration_invites_per_link_unlimited_uses,
      lifetime: Setting.group_registration_invites_per_link_lifetime_seconds,
      indefinite: Setting.group_registration_invites_per_link_indefinite,
    }
    example.run
  ensure
    Setting.group_registration_invites_enabled = previous[:enabled]
    Setting.group_registration_invites_shared_quota = previous[:quota]
    Setting.group_registration_invites_shared_quota_unlimited = previous[:quota_unlimited]
    Setting.group_registration_invites_per_link_max_uses = previous[:max_uses]
    Setting.group_registration_invites_per_link_unlimited_uses = previous[:unlimited_uses]
    Setting.group_registration_invites_per_link_lifetime_seconds = previous[:lifetime]
    Setting.group_registration_invites_per_link_indefinite = previous[:indefinite]
  end

  let(:actor) { user_with_role('Admin').account }

  def call(attributes)
    described_class.call(actor_account: actor, attributes: attributes, fingerprint: described_class.fingerprint)
  end

  it 'rejects a moderator, a negative quota, and a non-zero unlimited quota' do
    moderator = user_with_role('Moderator').account
    refused = described_class.call(actor_account: moderator, attributes: { shared_registration_quota: 1 }, fingerprint: described_class.fingerprint)
    expect(refused.code).to eq :not_authorized

    expect(call(shared_registration_quota: '-1', per_link_max_uses: '1', per_link_lifetime_seconds: '60').errors).to include(:shared_quota)
    expect(call(shared_quota_unlimited: '1', shared_registration_quota: '4', per_link_max_uses: '1', per_link_lifetime_seconds: '60').errors).to include(:shared_quota_unlimited_mismatch)
    expect(call(shared_registration_quota: '1', per_link_max_uses: '0', per_link_lifetime_seconds: '60').errors).to include(:per_link_max_uses)
    expect(call(shared_registration_quota: '1', per_link_max_uses: '1', per_link_lifetime_seconds: '2147483648').errors).to include(:per_link_lifetime_seconds)
    expect(Setting.group_registration_invites_shared_quota).to eq 0
  end

  it 'stores an unlimited fallback without copying it into the snapshot' do
    result = call(
      issuance_enabled: '0',
      shared_quota_unlimited: '1',
      shared_registration_quota: '0',
      per_link_unlimited_uses: '1',
      per_link_max_uses: '6',
      per_link_indefinite: '1',
      per_link_lifetime_seconds: '90'
    )

    expect(result.code).to eq :updated
    snapshot = GroupRegistrationInvites::SiteDefaults.snapshot
    expect(snapshot[:shared_quota_unlimited]).to eq true
    expect(snapshot[:shared_registration_quota]).to eq 0
    expect(snapshot[:per_link_max_uses]).to be_nil
    expect(snapshot[:per_link_lifetime_seconds]).to be_nil
    expect(Setting.group_registration_invites_per_link_max_uses).to eq 6
    expect(Setting.group_registration_invites_per_link_lifetime_seconds).to eq 90
  end
end
