# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationRequests::ApproveService do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    example.run
  ensure
    Setting.group_creation_requests = previous
  end

  let(:requester) { Fabricate(:user, account: Fabricate(:account, username: 'requester')) }
  let(:reviewer) { user_with_role('Owner') }

  def submit(username: 'freshgroup', requester_account: requester.account, **attrs)
    GroupCreationRequest.create!(
      {
        requester_account: requester_account,
        username: username,
        display_name: 'Fresh Group',
        note: 'A local group',
      }.merge(attrs)
    )
  end

  def approve(request, reviewer_account: reviewer.account)
    described_class.call(request: request, reviewer_account: reviewer_account)
  end

  it 'creates one user-less group, owner, policy snapshot, and audit row' do
    reviewer
    request = submit
    users = User.count

    result = approve(request)

    expect(result.code).to eq :approved
    group = result.group_account
    expect(group.user).to be_nil
    expect(group.group?).to be true
    expect(group.local?).to be true
    expect(group.discoverable).to be true
    expect(group.private_key).to be_present
    expect(group.public_key).to be_present
    expect(group.account_stat).to be_persisted
    expect(User.count).to eq users
    expect(group.managed_group).to be_approved_request
    expect(group.managed_group.creation_request).to eq request
    owner = GroupRoleAssignment.active.owner.find_by!(group_account: group)
    expect(owner.member_account).to eq requester.account
    expect(request.reload).to be_approved
    expect(request.initial_owner_account).to eq requester.account
    expect(request.reviewer_account).to eq reviewer.account
    policy = group.group_registration_invite_policy
    expect(policy.issuance_enabled).to be false
    expect(policy.shared_registration_quota).to eq 0
    expect(policy.shared_quota_unlimited).to be false
    expect(policy.per_link_unlimited_uses).to be false
    expect(policy.per_link_max_uses).to eq 1
    expect(policy.per_link_indefinite).to be false
    expect(policy.per_link_lifetime_seconds).to eq 604_800
    decision = request.decision
    expect(decision).to be_approved
    expect(decision.reviewer_account).to eq reviewer.account
    expect(decision.group_account).to eq group
    expect(Follow.where(account: requester.account, target_account: group)).to be_empty
  end

  it 'does not enqueue an icon job when the request has no icon' do
    request = submit
    expect(GroupCreationIcons::HandoffWorker).not_to receive(:perform_async)

    approve(request)
  end

  it 'lets an Admin role approve and refuses Moderator, a member, and a legacy admin flag' do
    admin = user_with_role('Admin')
    expect(approve(submit(username: 'admingroup'), reviewer_account: admin.account).code).to eq :approved

    moderator = user_with_role('Moderator')
    member = Fabricate(:user)
    legacy = Fabricate(:user, admin: true)
    pending = submit(username: 'modgroup')

    expect(approve(pending, reviewer_account: moderator.account).code).to eq :not_authorized
    expect(approve(pending, reviewer_account: member.account).code).to eq :not_authorized
    expect(approve(pending, reviewer_account: legacy.account).code).to eq :not_authorized
    expect(pending.reload).to be_pending
    expect(Account.where(username: 'modgroup')).to be_empty
  end

  it 'refuses approval while the feature flag is off and leaves the flag default false' do
    request = submit(username: 'flagged')
    Setting.group_creation_requests = false

    expect(approve(request).code).to eq :feature_disabled
    expect(request.reload).to be_pending
    expect(YAML.safe_load(File.read(Rails.root.join('config/settings.yml')), aliases: true).dig('defaults', 'group_creation_requests')).to be false
  end

  it 'keeps a pending request when the requester is no longer functional' do
    request = submit(username: 'stalled')
    requester.update!(disabled: true)

    expect(approve(request).code).to eq :invalid_requester
    expect(request.reload).to be_pending
    expect(Account.where(username: 'stalled')).to be_empty

    requester.update!(disabled: false, approved: false)
    expect(approve(request).code).to eq :invalid_requester
    expect(ManagedGroup.count).to eq 0
  end

  it 'keeps the request pending when the username was taken' do
    request = submit
    Fabricate(:account, username: 'freshgroup')

    expect(approve(request).code).to eq :username_taken
    expect(request.reload).to be_pending
    expect(GroupRoleAssignment.count).to eq 0
  end

  it 'approves only once' do
    request = submit(username: 'oncegroup')
    expect(approve(request).code).to eq :approved
    expect(approve(request.reload).code).to eq :not_pending
    expect(Account.where(username: 'oncegroup').count).to eq 1
    expect(GroupCreationDecision.where(group_creation_request: request).count).to eq 1
    expect(GroupRoleAssignment.active.owner.where(group_account: request.group_account).count).to eq 1
  end

  it 'rolls every row back when a later insert raises' do
    request = submit(username: 'rollbackgroup')
    allow(GroupRegistrationInvitePolicy).to receive(:copy_site_defaults!).and_raise(RuntimeError, 'boom')

    expect { approve(request) }.to raise_error(RuntimeError, 'boom')
    expect(request.reload).to be_pending
    expect(Account.where(username: 'rollbackgroup')).to be_empty
    expect(ManagedGroup.count).to eq 0
    expect(GroupRoleAssignment.count).to eq 0
    expect(GroupRegistrationInvitePolicy.count).to eq 0
    expect(GroupCreationDecision.count).to eq 0
  end

  it 'does not copy a later site-default change onto an approved group' do
    request = submit(username: 'snapgroup')
    group = approve(request).group_account
    policy = group.group_registration_invite_policy

    Setting.group_registration_invites_enabled = true
    Setting.group_registration_invites_shared_quota = 12

    expect(policy.reload.issuance_enabled).to be false
    expect(policy.shared_registration_quota).to eq 0
    expect(Fabricate(:account, username: 'legacyalone', actor_type: 'Group').group_registration_invite_policy).to be_nil
  end

  it 'rejects a negative or inconsistent invite policy' do
    managed_request = submit(username: 'policygroup')
    group = Fabricate(:account, username: 'policygroup', actor_type: 'Group')
    managed = ManagedGroup.create!(account: group, origin: :approved_request, creation_request: managed_request)
    invalid = GroupRegistrationInvitePolicy.new(
      managed_group: managed,
      group_account: group,
      issuance_enabled: false,
      shared_registration_quota: -1,
      shared_quota_unlimited: false,
      per_link_max_uses: 1,
      per_link_unlimited_uses: true,
      per_link_lifetime_seconds: 60,
      per_link_indefinite: true,
      copied_at: Time.current
    )

    expect(invalid).not_to be_valid
    expect(invalid.errors[:shared_registration_quota]).to be_present
    expect(invalid.errors[:per_link_max_uses]).to be_present
    expect(invalid.errors[:per_link_lifetime_seconds]).to be_present
  end
end
