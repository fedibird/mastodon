# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal group management CSRF' do
  before do
    https!
    stub_webpacker_manifest
    load Rails.root.join('db', 'seeds', '03_roles.rb')
  end

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  let(:owner) { Fabricate(:user) }
  let(:candidate) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }

  it 'does not appoint or offer ownership without a CSRF token' do
    creation_request = GroupCreationRequest.create!(requester_account: owner.account, username: 'p3csrfgroup', display_name: 'P3 CSRF', note: '')
    group = Fabricate(:account, username: creation_request.username, actor_type: 'Group')
    managed = ManagedGroup.create!(account: group, origin: :approved_request, creation_request: creation_request)
    GroupRoleAssignment.create!(group_account: group, member_account: owner.account, role: :owner, granted_by_account: reviewer.account)
    creation_request.record_approval!(reviewer_account: reviewer.account, group_account: group)

    sign_in owner, scope: :user
    expect do
      post appoint_moderator_settings_managed_group_path(managed), params: { username: candidate.account.username }
    end.not_to change(GroupRoleAssignment, :count)
    expect(response).to have_http_status(:unprocessable_entity)

    expect do
      post offer_transfer_settings_managed_group_path(managed), params: { username: candidate.account.username }
    end.not_to change(GroupOwnerTransferOffer, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
