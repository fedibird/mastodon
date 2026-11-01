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
    expect(call(shared_registration_quota: '2147483648', per_link_max_uses: '1', per_link_lifetime_seconds: '60').errors).to include(:shared_quota)
    expect(call(shared_registration_quota: '1.5', per_link_max_uses: '1', per_link_lifetime_seconds: '60').errors).to include(:shared_quota)
    expect(Setting.group_registration_invites_shared_quota).to eq 0
    expect(Setting.group_registration_invites_shared_quota_unlimited).to eq false
  end

  it 'detects a fallback-only change that the approval snapshot does not copy' do
    base = {
      issuance_enabled: '0',
      shared_quota_unlimited: '0',
      shared_registration_quota: '0',
      per_link_unlimited_uses: '1',
      per_link_max_uses: '1',
      per_link_indefinite: '1',
      per_link_lifetime_seconds: '90',
    }
    expect(call(base).code).to eq :updated
    first = described_class.fingerprint
    expect(GroupRegistrationInvites::SiteDefaults.snapshot[:per_link_max_uses]).to be_nil
    expect(GroupRegistrationInvites::SiteDefaults.snapshot[:per_link_lifetime_seconds]).to be_nil

    changed = described_class.call(actor_account: actor, attributes: base.merge(per_link_max_uses: '9', per_link_lifetime_seconds: '120'), fingerprint: first)
    expect(changed.code).to eq :updated
    expect(described_class.fingerprint).not_to eq first
    expect(Setting.group_registration_invites_per_link_max_uses).to eq 9

    stale = described_class.call(actor_account: actor, attributes: base.merge(per_link_max_uses: '3'), fingerprint: first)
    expect(stale.code).to eq :conflict
    expect(Setting.group_registration_invites_per_link_max_uses).to eq 9
  end

  it 'asks for the writer lock before comparing the stored values' do
    sql = []
    callback = lambda { |*_args, payload| sql << payload[:sql].to_s }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      expect(call(shared_registration_quota: '0', per_link_max_uses: '1', per_link_lifetime_seconds: '604800').code).to eq :updated
    end
    expect(sql).to include("SELECT pg_advisory_xact_lock(#{described_class::LOCK_KEY})")
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
