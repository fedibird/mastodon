# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::PostingIdentityRequestAllowancesController do
  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'allow_owner')) }
  let(:stranger) { Fabricate(:user, account: Fabricate(:account, username: 'allow_stranger')) }

  it 'lets a non-administrator choose who may request a link and stop that acceptance' do
    sign_in grantor, scope: :user

    post :create, params: { acct: grantee.account.username, scopes: %w(post media) }

    allowance = PostingIdentityRequestAllowance.last
    expect(response).to redirect_to(settings_posting_identity_links_path)
    expect(allowance.grantor_user).to eq grantor
    expect(allowance.allowed_scopes).to eq %w(post media)

    post :revoke, params: { id: allowance.id }

    expect(allowance.reload.revoked_at).to be_present
  end

  it 'does not let another account revoke or list that acceptance' do
    allowance = PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: stranger.account.username, scopes: %w(post))
    sign_in grantee, scope: :user

    post :revoke, params: { id: allowance.id }

    expect(allowance.reload.revoked_at).to be_nil
  end
end
