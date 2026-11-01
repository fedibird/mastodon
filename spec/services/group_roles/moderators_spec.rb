# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupRoles::Moderators do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner) { Fabricate(:user) }
  let(:moderator) { Fabricate(:user) }
  let(:outsider) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:creation_request) do
    GroupCreationRequest.create!(requester_account: owner.account, username: 'p3moderated', display_name: 'P3 Moderated', note: '')
  end
  let(:group) { Fabricate(:account, username: creation_request.username, actor_type: 'Group') }
  let(:managed) { ManagedGroup.create!(account: group, origin: :approved_request, creation_request: creation_request) }

  before do
    managed
    GroupRoleAssignment.create!(group_account: group, member_account: owner.account, role: :owner, granted_by_account: reviewer.account)
    creation_request.record_approval!(reviewer_account: reviewer.account, group_account: group)
  end

  def appoint(actor = owner.account, target = moderator.account)
    described_class.appoint(managed_group: managed, actor_account: actor, target_account: target)
  end

  def revoke(actor = owner.account, target_id = moderator.account.id)
    described_class.revoke(managed_group: managed, actor_account: actor, target_account_id: target_id)
  end

  it 'appoints a local moderator, keeps Follow independent, and records an audit' do
    expect { expect(appoint).to eq(:appointed) }.not_to change(Follow, :count)
    assignment = GroupRoleAssignment.active.moderator.find_by!(group_account_id: group.id, member_account_id: moderator.account.id)
    expect(assignment.granted_by_account).to eq(owner.account)
    expect(Admin::ActionLog.where(target: managed, action: 'appoint_group_moderator').count).to eq(1)
    expect(appoint).to eq(:already_assigned)
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id).count).to eq(1)
  end

  it 'allows the owner to revoke and the moderator to resign' do
    expect(appoint).to eq(:appointed)
    expect(revoke).to eq(:revoked)
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id)).to be_empty
    expect(appoint).to eq(:appointed)
    expect(described_class.resign(managed_group: managed, actor_account: moderator.account)).to eq(:resigned)
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id)).to be_empty
    expect(GroupRoleAssignment.where(group_account_id: group.id, member_account_id: moderator.account.id).count).to eq(2)
  end

  it 'refuses a moderator, outsider, remote, bot, group and self appointment' do
    expect(appoint(outsider.account)).to eq(:not_authorized)
    expect(appoint(moderator.account)).to eq(:not_authorized)
    expect(appoint(owner.account, owner.account)).to eq(:already_assigned)
    expect(appoint(owner.account, Fabricate(:account, username: 'remoteP3', domain: 'other.example'))).to eq(:invalid_target)
    expect(appoint(owner.account, group)).to eq(:invalid_target)
    bot = Fabricate(:user, account: Fabricate(:account, username: 'p3bot', actor_type: 'Service'))
    expect(appoint(owner.account, bot.account)).to eq(:invalid_target)
    expect(revoke(outsider.account)).to eq(:not_authorized)
    expect(described_class.resign(managed_group: managed, actor_account: owner.account)).to eq(:not_authorized)
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id)).to be_empty
  end

  it 'does not save roles if the audit cannot be written' do
    allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)
    expect(appoint).to eq(:audit_failed)
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id)).to be_empty
  end
end
