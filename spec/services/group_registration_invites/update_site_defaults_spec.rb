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

  def database_setting(key)
    row = Setting.unscoped.find_by(thing_type: nil, thing_id: nil, var: key)
    row ? row.value : 0
  end

  def defaults_attributes(quota)
    {
      issuance_enabled: '0',
      shared_quota_unlimited: '0',
      shared_registration_quota: quota,
      per_link_unlimited_uses: '0',
      per_link_max_uses: '1',
      per_link_indefinite: '0',
      per_link_lifetime_seconds: '604800',
    }
  end

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

  it 'keeps the shared cache on the committed value when the audit or the database write fails' do
    expect(Setting.group_registration_invites_shared_quota).to eq 0
    allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)

    failed = call(shared_registration_quota: '7', per_link_max_uses: '1', per_link_lifetime_seconds: '60')

    expect(failed.code).to eq :audit_failed
    expect(Setting.group_registration_invites_shared_quota).to eq database_setting('group_registration_invites_shared_quota')
    expect(Setting.group_registration_invites_shared_quota).to eq 0

    RSpec::Mocks.space.proxy_for(GroupAdministration::Audit).reset
    saves = 0
    allow_any_instance_of(Setting).to receive(:save!).and_wrap_original do |method, *args|
      saves += 1
      raise ActiveRecord::StatementInvalid, 'forced write failure' if saves == 4

      method.call(*args)
    end

    expect { call(shared_registration_quota: '6', per_link_max_uses: '1', per_link_lifetime_seconds: '60') }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Setting.group_registration_invites_shared_quota).to eq database_setting('group_registration_invites_shared_quota')
    expect(Setting.group_registration_invites_shared_quota).to eq 0
  end

  it 'does not let an approval inside the open transaction copy the uncommitted quota' do
    Setting.group_creation_requests = true
    requester = Fabricate(:user)
    reviewer = actor
    first = GroupCreationRequest.create!(requester_account: requester.account, username: 'duringcopy', display_name: 'During', note: 'during')
    second = GroupCreationRequest.create!(requester_account: requester.account, username: 'aftercopy', display_name: 'After', note: 'after')
    expect(Setting.group_registration_invites_shared_quota).to eq 0
    seen = nil
    copied_during = nil
    allow(GroupAdministration::Audit).to receive(:record!).and_wrap_original do |method, **kwargs|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          seen = Setting.group_registration_invites_shared_quota
        end
      end.join
      copied_during = GroupCreationRequests::ApproveService.call(request: first, reviewer_account: reviewer)
      method.call(**kwargs)
    end

    result = call(shared_registration_quota: '5', per_link_max_uses: '1', per_link_lifetime_seconds: '60')
    copied_after = GroupCreationRequests::ApproveService.call(request: second, reviewer_account: reviewer)

    expect(result.code).to eq :updated
    expect(seen).to eq 0
    expect(copied_during.group_account.group_registration_invite_policy.shared_registration_quota).to eq 0
    expect(copied_after.group_account.group_registration_invite_policy.shared_registration_quota).to eq 5
    expect(Setting.group_registration_invites_shared_quota).to eq database_setting('group_registration_invites_shared_quota')
    expect(Setting.group_registration_invites_shared_quota).to eq 5
  ensure
    Setting.group_creation_requests = false
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

RSpec.describe 'group invite defaults from two connections' do
  # The second connection must see a committed update. The example
  # transaction would hide that commit and hold the advisory lock.
  self.use_transactional_tests = false

  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  after do
    Setting.group_registration_invites_enabled = false
    Setting.group_registration_invites_shared_quota = 0
    Setting.group_registration_invites_shared_quota_unlimited = false
    Setting.group_registration_invites_per_link_max_uses = 1
    Setting.group_registration_invites_per_link_unlimited_uses = false
    Setting.group_registration_invites_per_link_lifetime_seconds = 604_800
    Setting.group_registration_invites_per_link_indefinite = false
  end

  def defaults_attributes(quota)
    {
      issuance_enabled: '0',
      shared_quota_unlimited: '0',
      shared_registration_quota: quota,
      per_link_unlimited_uses: '0',
      per_link_max_uses: '1',
      per_link_indefinite: '0',
      per_link_lifetime_seconds: '604800',
    }
  end

  it 'lets one connection commit and rejects the other fingerprint' do
    actor_id = user_with_role('Admin').account.id
    fingerprint = GroupRegistrationInvites::UpdateSiteDefaults.fingerprint
    codes = []
    errors = []
    guard = Mutex.new

    threads = %w(4 8).map do |quota|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          result = GroupRegistrationInvites::UpdateSiteDefaults.call(
            actor_account: Account.find(actor_id),
            attributes: defaults_attributes(quota),
            fingerprint: fingerprint
          )
          guard.synchronize { codes << result.code }
        end
      rescue StandardError => e
        guard.synchronize { errors << "#{e.class}: #{e.message}" }
      end
    end
    threads.each { |thread| thread.join(15) || raise('invite default update thread did not finish') }

    expect(errors).to eq []
    expect(codes.sort).to eq %i(conflict updated)
    database_quota = Setting.unscoped.find_by!(thing_type: nil, thing_id: nil, var: 'group_registration_invites_shared_quota').value
    expect([4, 8]).to include(database_quota)
    expect(Setting.group_registration_invites_shared_quota).to eq database_quota
  end
end
