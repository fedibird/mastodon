# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PostingIdentitiesController do
  render_views

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'cataloged', display_name: 'Cataloged')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'read') }

  before do
    grantee.account.update!(username: 'catalog_owner', display_name: 'Catalog Owner')
    allow(controller).to receive(:doorkeeper_token) { token }
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
    issued = PostingIdentity::LinkRequestIssuer.call!(
      requester: grantee,
      acct: grantor.account.username,
      scopes: %w(post),
      ip: '203.0.113.77'
    )
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  it 'adds the delegated account without marking it ready to send' do
    get :index

    identities = body_as_json[:identities]
    delegated = identities.find { |identity| identity[:kind] == 'delegated' }
    own = identities.find { |identity| identity[:id] == "local:#{grantee.account.id}" }

    expect(response).to have_http_status(200)
    expect(body_as_json[:default_identity_id]).to eq "local:#{grantee.account.id}"
    expect(identities.map { |identity| identity[:account][:id] }).to contain_exactly(grantee.account.id.to_s, grantor.account.id.to_s)
    expect(own).to include(authorization: 'ready', kind: 'local')
    expect(own.keys).not_to include(:delegation)
    expect(delegated).to include(
      id: "delegated:#{grantor.account.id}",
      kind: 'delegated',
      provider: 'fedibird',
      authorization: 'unavailable'
    )
    expect(delegated[:capabilities][:post]).to eq 'unavailable'
    expect(delegated[:capabilities][:media]).to eq 'unavailable'
    expect(delegated[:delegation]).to include(state: 'active', scopes: ['post'])
    expect(delegated[:account]).to include(id: grantor.account.id.to_s, acct: 'cataloged', display_name: 'Cataloged')
    expect(response.body).not_to include(grantee.email)
    expect(response.body).not_to include(grantor.email)
    expect(response.body).not_to include('token_digest')
  end
end
