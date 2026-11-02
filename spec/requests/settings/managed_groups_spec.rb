# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal group role management' do # rubocop:disable Metrics/BlockLength
  before do
    https!
    stub_webpacker_manifest
    load Rails.root.join('db', 'seeds', '03_roles.rb')
  end

  let(:owner) { Fabricate(:user) }
  let(:moderator) { Fabricate(:user, account: Fabricate(:account, username: 'p3webmod')) }
  let(:successor) { Fabricate(:user, account: Fabricate(:account, username: 'p3webnext')) }
  let(:outsider) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:creation_request) do
    GroupCreationRequest.create!(requester_account: owner.account, username: 'p3webgroup', display_name: 'P3 Web Group', note: '')
  end
  let(:group) { Fabricate(:account, username: creation_request.username, actor_type: 'Group') }
  let(:managed) { ManagedGroup.create!(account: group, origin: :approved_request, creation_request: creation_request) }

  before do
    managed
    GroupRoleAssignment.create!(group_account: group, member_account: owner.account, role: :owner, granted_by_account: reviewer.account)
    creation_request.record_approval!(reviewer_account: reviewer.account, group_account: group)
  end

  it 'shows only personal groups and permits an owner to appoint and remove a moderator' do
    sign_in owner, scope: :user
    get settings_managed_groups_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('p3webgroup')

    get settings_managed_group_path(managed)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('group_role_management.appoint'))

    post appoint_moderator_settings_managed_group_path(managed), params: { username: moderator.account.username }
    expect(response).to redirect_to(settings_managed_group_path(managed))
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id, member_account_id: moderator.account.id)).to exist

    post revoke_moderator_settings_managed_group_path(managed), params: { member_account_id: moderator.account.id }
    expect(response).to redirect_to(settings_managed_group_path(managed))
    expect(GroupRoleAssignment.active.moderator.where(group_account_id: group.id)).to be_empty
    expect(GroupRoleAssignment.active.owner.where(group_account_id: group.id).count).to eq(1)
  end

  it 'lets only the moderator resign and never treats them as a server administrator' do
    GroupRoles::Moderators.appoint(managed_group: managed, actor_account: owner.account, target_account: moderator.account)
    sign_in moderator, scope: :user
    get settings_managed_group_path(managed)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t('group_role_management.appoint_button'))

    post appoint_moderator_settings_managed_group_path(managed), params: { username: successor.account.username }
    expect(response).to have_http_status(:forbidden)
    post offer_transfer_settings_managed_group_path(managed), params: { username: successor.account.username }
    expect(response).to have_http_status(:forbidden)

    post resign_moderator_settings_managed_group_path(managed)
    expect(response).to redirect_to(settings_managed_groups_path)
    expect(GroupRoleAssignment.active.where(group_account_id: group.id, member_account_id: moderator.account.id)).to be_empty
  end

  it 'scopes another user out of group screens, writes, and other candidates offers' do
    sign_in outsider, scope: :user
    get settings_managed_groups_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('p3webgroup')
    get settings_managed_group_path(managed)
    expect(response).to have_http_status(:not_found)
    post appoint_moderator_settings_managed_group_path(managed), params: { username: outsider.account.username }
    expect(response).to have_http_status(:not_found)

    expect(GroupRoles::OwnerTransfers.offer(managed_group: managed, actor_account: owner.account, candidate_account: successor.account)).to eq(:offered)
    offer = GroupOwnerTransferOffer.pending.find_by!(group_account_id: group.id)
    post settings_accept_group_owner_transfer_offer_path(offer)
    expect(response).to have_http_status(:not_found)
    expect(offer.reload).to be_pending
    expect(GroupRoleAssignment.active.owner.find_by!(group_account_id: group.id).member_account).to eq(owner.account)
  end

  it 'only changes owner after the named successor accepts from their own account' do
    sign_in owner, scope: :user
    post offer_transfer_settings_managed_group_path(managed), params: { username: successor.account.username }
    expect(response).to redirect_to(settings_managed_group_path(managed))
    offer = GroupOwnerTransferOffer.pending.find_by!(group_account_id: group.id)

    sign_in successor, scope: :user
    get settings_managed_groups_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('p3webgroup', I18n.t('group_role_management.accept'))
    post settings_accept_group_owner_transfer_offer_path(offer)
    expect(response).to redirect_to(settings_managed_groups_path)
    expect(GroupRoleAssignment.active.owner.where(group_account_id: group.id).pluck(:member_account_id)).to eq([successor.account.id])
    expect(creation_request.reload.initial_owner_account).to eq(owner.account)

    sign_in owner, scope: :user
    get settings_managed_group_path(managed)
    expect(response).to have_http_status(:not_found)
  end
end
