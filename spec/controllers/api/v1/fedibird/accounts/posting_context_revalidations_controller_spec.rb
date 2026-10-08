# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::Accounts::PostingContextRevalidationsController do
  render_views

  let(:user) { user_with_role('Owner') }
  let(:scopes) { 'write' }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:account) { remote_group }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(PostingContext::RevalidateGroupEvidenceWorker).to receive(:perform_async)
  end

  after do
    RedisConfiguration.with do |redis|
      redis.scan_each(match: 'posting_context:revalidation:v1:*') { |key| redis.del(key) }
    end
  end

  describe 'POST #create' do
    it 'queues revalidation for an unsupported remote group without contacting it' do
      expect(ActivityPub::FetchRemoteAccountService).not_to receive(:new)
      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)

      post :create, params: { account_id: account.id, url: 'https://evil.example/actor', collection: 'https://evil.example/collection' }

      expect(response).to have_http_status(202)
      expect(body_as_json[:state]).to eq 'queued'
      expect(body_as_json[:account_id]).to eq account.id.to_s
      expect(body_as_json[:request_id]).to be_present
      expect(body_as_json[:requested_at]).to be_present
      expect(response.body).not_to include('evil.example')
      expect(PostingContext::RevalidateGroupEvidenceWorker).to have_received(:perform_async).with(account.id, body_as_json[:request_id])
    end

    it 'returns the same job when a request is already in flight' do
      post :create, params: { account_id: account.id }
      request_id = body_as_json[:request_id]

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(202)
      expect(body_as_json[:request_id]).to eq request_id
      expect(PostingContext::RevalidateGroupEvidenceWorker).to have_received(:perform_async).once
    end

    it 'returns retry-after during the cooldown' do
      post :create, params: { account_id: account.id }
      request_id = body_as_json[:request_id]
      registry = PostingContext::RevalidationRegistry.new
      registry.mark_running!(account.id, request_id)
      registry.finish!(account.id, request_id, PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'completed', actor: 'refreshed', affiliations: 'refreshed'))

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(429)
      expect(response.headers['Retry-After'].to_i).to be_positive
      expect(body_as_json[:error]).to eq 'cooldown'
      expect(PostingContext::RevalidateGroupEvidenceWorker).to have_received(:perform_async).once
    end

    it 'does not enqueue a local group, a person, a suspended group, or a non-activitypub group' do
      [local_group, person, suspended_group, ostatus_group].each do |target|
        post :create, params: { account_id: target.id }

        expect(response).to have_http_status(422)
      end

      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end

    it 'does not enqueue a domain-blocked group' do
      Fabricate(:domain_block, domain: 'blocked.example', severity: :suspend)
      blocked = remote_group(domain: 'blocked.example', uri: 'https://blocked.example/users/group')

      post :create, params: { account_id: blocked.id }

      expect(response).to have_http_status(422)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end

    it 'rejects a non-administrator' do
      user.update_columns(role_id: nil)

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(403)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)

      user.update_columns(role_id: UserRole.find_by!(name: 'Admin').id)

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(403)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end

    it 'rejects an unauthenticated request' do
      allow(controller).to receive(:doorkeeper_token) { nil }

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(401)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end

    it 'rejects a token without write scope' do
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }

      post :create, params: { account_id: account.id }

      expect(response).to have_http_status(403)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end
  end

  describe 'GET #show' do
    let(:scopes) { 'read' }

    it 'returns idle without starting a fetch' do
      expect(ActivityPub::FetchRemoteAccountService).not_to receive(:new)
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to receive(:perform_async)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq(state: 'idle', account_id: account.id.to_s)
    end

    it 'returns the stored job state' do
      created = PostingContext::RevalidationRegistry.new.request!(account, requester: user)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:state]).to eq 'queued'
      expect(body_as_json[:request_id]).to eq created.payload[:request_id]
      expect(PostingContext::RevalidateGroupEvidenceWorker).not_to have_received(:perform_async)
    end
  end

  def remote_group(domain: 'mitra.example', uri: "https://#{domain}/users/group")
    Fabricate(
      :account,
      username: 'group',
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: uri,
      inbox_url: "https://#{domain}/users/group/inbox"
    )
  end

  def local_group
    Fabricate(:account, username: 'localgroup', actor_type: 'Group')
  end

  def person
    Fabricate(
      :account,
      username: 'alice',
      domain: 'people.example',
      actor_type: 'Person',
      protocol: :activitypub,
      uri: 'https://people.example/users/alice',
      inbox_url: 'https://people.example/users/alice/inbox'
    )
  end

  def suspended_group
    remote_group(domain: 'suspended.example', uri: 'https://suspended.example/users/group').tap do |group|
      group.update_columns(suspended_at: Time.now.utc, suspension_origin: Account.suspension_origins[:local])
    end
  end

  def ostatus_group
    remote_group(domain: 'ostatus.example', uri: 'https://ostatus.example/users/group').tap do |group|
      group.update_columns(protocol: Account.protocols[:ostatus])
    end
  end
end
