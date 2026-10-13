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
    expect(response.body).not_to include('affiliation_uri')
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

  it 'returns a minimal canCreate result for a Mitra group and not the affiliation list' do
    delegation = delegate!
    Node.create!(domain: 'mitra.example', info: { 'software_name' => 'mitra' })
    remote = Fabricate(
      :account,
      username: 'circle',
      domain: 'mitra.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://mitra.example/users/circle',
      inbox_url: 'https://mitra.example/users/circle/inbox'
    )
    remote.update_columns(
      affiliations_fetched_at: Time.now.utc,
      permission_definitions_fetched_at: Time.now.utc,
      can_create_affiliation: 'none'
    )
    GroupAffiliation.create!(
      group_account: remote,
      subject_uri: ActivityPub::TagManager.instance.uri_for(grantor.account),
      relationship: 'admin',
      affiliation_uri: 'https://mitra.example/relationships/secret'
    )

    get :show, params: { account_id: remote.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(200)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(body_as_json[:viewer_evidence]).to be_nil
    expect(body_as_json[:sender_posting]).to include(
      identity_id: "delegated:#{grantor.account.id}",
      delegation_id: delegation.id.to_s,
      can_post: true
    )
    expect(body_as_json.dig(:sender_posting, :permission)).to include(status: 'allowed', confirmed: true, freshness: 'current')
    expect(body_as_json.dig(:sender_posting, :delivery)).to include(status: 'supported', adapter: 'mitra_group')
    expect(response.body).not_to include('affiliation_uri')
    expect(response.body).not_to include('relationships/secret')
    expect(response.body).not_to include(grantor.email)
  end

  it 'returns a minimal NodeBB canCreate result and does not copy affiliation URIs' do
    delegation = delegate!
    Node.create!(domain: 'nodebb.example', info: { 'software_name' => 'nodebb' })
    remote = Fabricate(
      :account,
      username: 'category',
      domain: 'nodebb.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://nodebb.example/category/1',
      inbox_url: 'https://nodebb.example/category/1/inbox'
    )
    remote.update_columns(
      affiliations_fetched_at: Time.now.utc,
      permission_definitions_fetched_at: Time.now.utc,
      can_create_affiliation: 'none'
    )
    GroupAffiliation.create!(
      group_account: remote,
      subject_uri: ActivityPub::TagManager.instance.uri_for(grantor.account),
      relationship: 'admin',
      affiliation_uri: 'https://nodebb.example/relationships/secret'
    )

    get :show, params: { account_id: remote.id, posting_identity_id: "delegated:#{grantor.account.id}" }

    expect(response).to have_http_status(200)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(body_as_json[:viewer_evidence]).to be_nil
    expect(body_as_json[:sender_posting].keys.map(&:to_s)).to contain_exactly('identity_id', 'delegation_id', 'can_post', 'permission', 'delivery')
    expect(body_as_json[:sender_posting]).to include(
      identity_id: "delegated:#{grantor.account.id}",
      delegation_id: delegation.id.to_s,
      can_post: true
    )
    expect(body_as_json.dig(:sender_posting, :permission)).to include(status: 'allowed', confirmed: true, freshness: 'current')
    expect(body_as_json.dig(:sender_posting, :delivery)).to include(status: 'supported', adapter: 'nodebb_group', authority: 'compatibility')
    expect(body_as_json.dig(:context, :key)).to eq "protocol:fep-1b12-nodebb:#{remote.id}"
    expect(body_as_json.dig(:discovery, :adapter)).to eq 'nodebb_group'
    expect(response.body).not_to include('affiliation_uri')
    expect(response.body).not_to include('relationships/secret')
    expect(response.body).not_to include(grantor.email)
  end

  it 'recognizes Lemmy and PieFed but does not turn fresh canCreate into delegated send permission' do
    delegation = delegate!
    %w(lemmy piefed).each do |software|
      domain = "#{software}.example"
      Node.create!(domain: domain, info: { 'software_name' => software })
      remote = Fabricate(
        :account,
        username: 'technology',
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{domain}/c/technology",
        inbox_url: "https://#{domain}/c/technology/inbox"
      )
      remote.update_columns(
        affiliations_fetched_at: Time.now.utc,
        permission_definitions_fetched_at: Time.now.utc,
        can_create_affiliation: 'none'
      )
      GroupAffiliation.create!(
        group_account: remote,
        subject_uri: ActivityPub::TagManager.instance.uri_for(grantee.account),
        relationship: 'admin',
        affiliation_uri: "https://#{domain}/relationships/secret"
      )

      get :show, params: { account_id: remote.id, posting_identity_id: "delegated:#{grantor.account.id}" }

      expect(response).to have_http_status(200)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(body_as_json[:viewer_evidence]).to be_nil
      expect(body_as_json.dig(:discovery, :adapter)).to eq "#{software}_group"
      expect(body_as_json.dig(:context, :key)).to eq "protocol:fep-1b12-#{software}:#{remote.id}"
      expect(body_as_json.dig(:context, :source, :id)).to eq "compat:#{software}-group-note"
      expect(body_as_json[:sender_posting]).to include(
        identity_id: "delegated:#{grantor.account.id}",
        delegation_id: delegation.id.to_s,
        can_post: false
      )
      expect(body_as_json.dig(:sender_posting, :permission, :confirmed)).to be true
      expect(body_as_json.dig(:sender_posting, :delivery)).to include(status: 'unsupported', adapter: "#{software}_group")
      expect(response.body).not_to include('relationships/secret')
      expect(response.body).not_to include(grantor.email)
    end
  end
end
