# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupRoleAssignment do # rubocop:disable Metrics/BlockLength
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:requester) { Fabricate(:user) }
  let(:owner) { Fabricate(:user) }
  let(:moderator) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:request) do
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'rolegroup',
      display_name: 'Role Group',
      note: ''
    )
  end
  let(:group) { Fabricate(:account, username: request.username, actor_type: 'Group') }
  let!(:managed) { ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request) }

  def assign_owner(member = owner.account)
    described_class.create!(
      group_account: group,
      member_account: member,
      role: :owner,
      granted_by_account: reviewer.account,
      granted_at: Time.current
    )
  end

  it 'keeps roles independent from follow and from group affiliation' do
    follow = Fabricate(:follow, account: owner.account, target_account: group)
    affiliation = GroupAffiliation.create!(group_account: group, subject_uri: 'https://remote.example/users/owner', relationship: 'admin')

    assignment = nil
    expect { assignment = assign_owner }.not_to(change { [Follow.count, GroupAffiliation.count] })
    expect(follow.reload).to be_persisted
    expect(affiliation.reload).to be_persisted
    expect(assignment.revoke!).to be true
    expect(Follow.exists?(follow.id)).to be true
    expect(described_class.where(id: assignment.id)).to exist
  end

  it 'refuses a group, a remote account, a bot, or an unmanaged group' do
    expect(described_class.new(group_account: group, member_account: group, role: :owner, granted_at: Time.current)).not_to be_valid

    remote = Fabricate(:account, username: 'remoteowner', domain: 'example.com')
    expect(described_class.new(group_account: group, member_account: remote, role: :owner, granted_at: Time.current)).not_to be_valid

    bot = Fabricate(:user, account: Fabricate(:account, username: 'rolebot', actor_type: 'Service'))
    expect(described_class.new(group_account: group, member_account: bot.account, role: :moderator, granted_at: Time.current)).not_to be_valid

    legacy = Fabricate(:account, username: 'unmanagedgroup', actor_type: 'Group')
    expect(described_class.new(group_account: legacy, member_account: owner.account, role: :owner, granted_at: Time.current)).not_to be_valid
    expect(described_class.where(group_account_id: legacy.id)).to be_empty
    expect(legacy.reload.managed_group).to be_nil
  end

  it 'allows one active owner and a distinct moderator, including after revocation' do
    first = assign_owner
    duplicate = described_class.new(group_account: group, member_account: Fabricate(:user).account, role: :owner, granted_at: Time.current)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors.added?(:role, :taken)).to be true

    same_person = described_class.new(group_account: group, member_account: owner.account, role: :moderator, granted_at: Time.current)
    expect(same_person).not_to be_valid
    expect(same_person.errors.added?(:member_account_id, :taken)).to be true

    other = described_class.create!(group_account: group, member_account: moderator.account, role: :moderator, granted_at: Time.current)
    expect(other).to be_moderator

    request.record_approval!(reviewer_account: reviewer.account, group_account: group)
    expect { first.revoke! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(first.reload.revoked_at).to be_nil

    expect(other.revoke!).to be true
    expect(other.reload.revoked_at).to be_present
    again = described_class.create!(group_account: group, member_account: moderator.account, role: :moderator, granted_at: Time.current)
    expect(again.revoked_at).to be_nil
  end

  it 'enforces one active owner and no self-assignment in the database' do
    assign_owner
    second = described_class.new(
      group_account: group,
      member_account: Fabricate(:user).account,
      role: :owner,
      granted_at: Time.current
    )

    expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)

    self_owned = described_class.new(group_account: group, member_account: group, role: :moderator, granted_at: Time.current)
    expect { self_owned.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'does not create a member table' do
    expect(ActiveRecord::Base.connection.table_exists?(:group_members)).to be false
    expect(ActiveRecord::Base.connection.table_exists?(:group_memberships)).to be false
    expect(managed).to be_persisted
  end
end
