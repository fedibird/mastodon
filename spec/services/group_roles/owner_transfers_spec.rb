# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupRoles::OwnerTransfers do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:owner) { Fabricate(:user) }
  let(:successor) { Fabricate(:user) }
  let(:outsider) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:creation_request) do
    GroupCreationRequest.create!(requester_account: owner.account, username: 'p3transfer', display_name: 'P3 Transfer', note: '')
  end
  let(:group) { Fabricate(:account, username: creation_request.username, actor_type: 'Group') }
  let(:managed) { ManagedGroup.create!(account: group, origin: :approved_request, creation_request: creation_request) }

  before do
    managed
    GroupRoleAssignment.create!(group_account: group, member_account: owner.account, role: :owner, granted_by_account: reviewer.account)
    creation_request.record_approval!(reviewer_account: reviewer.account, group_account: group)
  end

  def offer(candidate = successor.account, actor = owner.account)
    described_class.offer(managed_group: managed, actor_account: actor, candidate_account: candidate)
  end

  def pending
    GroupOwnerTransferOffer.pending.find_by!(group_account_id: group.id)
  end

  it 'only transfers after the named successor accepts, keeping founding ownership and Follow unchanged' do
    expect(offer).to eq(:offered)
    expect(GroupRoleAssignment.active.owner.find_by!(group_account_id: group.id).member_account).to eq(owner.account)
    expect(described_class.accept(offer: pending, actor_account: outsider.account)).to eq(:not_authorized)
    expect do
      expect(described_class.accept(offer: pending, actor_account: successor.account)).to eq(:accepted)
    end.not_to change(Follow, :count)
    expect(GroupRoleAssignment.active.owner.where(group_account_id: group.id).pluck(:member_account_id)).to eq([successor.account.id])
    expect(creation_request.reload.initial_owner_account).to eq(owner.account)
    expect(GroupOwnerTransferOffer.find(pending.id)).to be_accepted if GroupOwnerTransferOffer.pending.exists?(group_account_id: group.id) # no pending after acceptance
    expect(GroupOwnerTransferOffer.accepted.where(group_account_id: group.id).count).to eq(1)
    expect(Admin::ActionLog.where(target: managed, action: 'accept_group_ownership').count).to eq(1)
  end

  it 'replaces an active moderator with one owner role in the same transaction' do
    GroupRoleAssignment.create!(group_account: group, member_account: successor.account, role: :moderator, granted_by_account: owner.account)
    expect(offer).to eq(:offered)
    expect(described_class.accept(offer: pending, actor_account: successor.account)).to eq(:accepted)
    expect(GroupRoleAssignment.active.where(group_account_id: group.id, member_account_id: successor.account.id).pluck(:role)).to eq(['owner'])
    expect(GroupRoleAssignment.where(group_account_id: group.id, member_account_id: successor.account.id).count).to eq(2)
  end

  it 'refuses an outsider offer, self-offer, missing successor and duplicate acceptance' do
    expect(offer(successor.account, outsider.account)).to eq(:not_authorized)
    expect(offer(owner.account)).to eq(:invalid_target)
    expect(offer(nil)).to eq(:invalid_target)
    expect(offer).to eq(:offered)
    expect(offer).to eq(:already_pending)
    old = pending
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:accepted)
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:not_pending)
  end

  it 'cancels a pending offer and prevents acceptance' do
    expect(offer).to eq(:offered)
    old = pending
    expect(described_class.cancel(offer: old, actor_account: outsider.account)).to eq(:not_authorized)
    expect(described_class.cancel(offer: old, actor_account: owner.account)).to eq(:cancelled)
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:not_pending)
    expect(GroupRoleAssignment.active.owner.find_by!(group_account_id: group.id).member_account).to eq(owner.account)
  end

  it 'expires after 7 days without transferring ownership' do
    expect(offer).to eq(:offered)
    old = pending
    travel_to(8.days.from_now) do
      expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:expired)
    end
    expect(GroupRoleAssignment.active.owner.find_by!(group_account_id: group.id).member_account).to eq(owner.account)
  end

  it 'refuses when the original owner has changed or the successor is no longer functional' do
    expect(offer).to eq(:offered)
    old = pending
    successor.update!(disabled: true)
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:not_authorized)
    successor.update!(disabled: false)
    GroupRoleAssignment.transfer_owner!(group_account: group, member_account: outsider.account, granted_by_account: owner.account)
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:stale_owner)
  end

  it 'rolls back moderator revocation, owner replacement, and accepted state when auditing fails' do
    GroupRoleAssignment.create!(group_account: group, member_account: successor.account, role: :moderator, granted_by_account: owner.account)
    expect(offer).to eq(:offered)
    old = pending
    allow(GroupAdministration::Audit).to receive(:record!).and_raise(GroupAdministration::Audit::Error)
    expect(described_class.accept(offer: old, actor_account: successor.account)).to eq(:audit_failed)
    expect(old.reload).to be_pending
    expect(GroupRoleAssignment.active.owner.find_by!(group_account_id: group.id).member_account).to eq(owner.account)
    expect(GroupRoleAssignment.active.moderator.find_by!(group_account_id: group.id).member_account).to eq(successor.account)
  end
end
