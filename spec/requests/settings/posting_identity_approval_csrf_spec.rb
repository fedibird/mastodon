# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Posting identity approval CSRF' do
  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'csrf_approver')) }

  before { stub_webpacker_manifest }

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it 'does not approve a POST that lacks the CSRF token' do
    issued = PostingIdentity::LinkRequestIssuer.call!(
      requester: grantee,
      acct: grantor.account.username,
      scopes: ['post'],
      ip: '203.0.113.92'
    )
    sign_in grantor, scope: :user

    expect do
      post settings_posting_identity_approval_path, params: { token: issued.token }
    end.not_to change(PostingIdentityDelegation, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(issued.request.reload.consumed_at).to be_nil
  end
end
