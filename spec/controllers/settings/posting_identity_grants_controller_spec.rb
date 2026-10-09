# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::PostingIdentityGrantsController do
  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'grant_owner')) }

  def delegation
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.93')
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  it 'lets a non-administrator grantor revoke' do
    record = delegation
    sign_in grantor, scope: :user

    post :revoke, params: { id: record.id }

    expect(response).to redirect_to(settings_posting_identity_links_path)
    expect(record.reload.revoked_at).to be_present
    expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: record, operation: 'post')).to be false
  end

  it 'lets the grantee unlink and ignores another user' do
    record = delegation
    stranger = Fabricate(:user)
    sign_in stranger, scope: :user

    post :revoke, params: { id: record.id }

    expect(record.reload.revoked_at).to be_nil

    sign_out :user
    sign_in grantee, scope: :user
    post :unlink, params: { id: record.id }

    expect(record.reload.revoked_at).to be_present
  end
end
