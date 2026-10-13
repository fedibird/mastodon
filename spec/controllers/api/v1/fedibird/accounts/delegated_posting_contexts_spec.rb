# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::Accounts::PostingContextsController do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:group) { Fabricate(:user, account: Fabricate(:account, username: 'localsquad', actor_type: 'Group')).account }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'read:accounts') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def delegate!(scopes: %w(post group))
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: scopes, ip: '203.0.113.41')
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  it 'keeps the signed-in discovery response unchanged' do
    get :show, params: { account_id: group.id }

    expect(response).to have_http_status(200)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(body_as_json).not_to have_key(:sender_posting)
    expect(body_as_json[:viewer_evidence]).to be_nil
    expect(body_as_json.dig(:discovery, :adapter)).to eq 'fedibird_group'
  end

  it 'returns only the granting account follow for a delegated identity' do
    delegation = delegate!
    grantor.account.follow!(group)
    grantee.account.follow!(Fabricate(:account, username: 'elsewhere'))

    get :show, params: { account_id: group.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(200)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(body_as_json[:viewer_evidence]).to be_nil
    expect(body_as_json[:sender_posting]).to include(
      identity_id: "delegated:#{grantor.account.id}",
      delegation_id: delegation.id.to_s,
      can_post: true,
      following: true
    )
    expect(response.body).not_to include(grantor.email)
    expect(response.body).not_to include(grantee.email)
  end

  it 'does not report a follow the granting account does not have' do
    delegate!
    grantee.account.follow!(group)

    get :show, params: { account_id: group.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(200)
    expect(body_as_json.dig(:sender_posting, :following)).to be false
    expect(body_as_json.dig(:sender_posting, :can_post)).to be false
  end

  it 'refuses a grant without group and a remote group stays unpostable' do
    delegation = delegate!(scopes: %w(post))

    get :show, params: { account_id: group.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(403)

    PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post group))
    remote = Fabricate(:account, username: 'remote', domain: 'example.com', actor_type: 'Group')

    get :show, params: { account_id: remote.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(200)
    expect(body_as_json.dig(:sender_posting, :can_post)).to be false
    expect(body_as_json[:viewer_evidence]).to be_nil
  end
end
