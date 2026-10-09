# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PostingIdentitiesController do
  render_views

  let(:account) { Fabricate(:account, username: 'ada', display_name: 'Ada') }
  let(:owner) { user_with_role('Owner', account: account) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #index' do
    it 'returns only the signed-in account and no credentials' do
      other = Fabricate(:user)

      get :index, params: { account_id: other.account_id, identity_id: "local:#{other.account_id}" }

      expect(response).to have_http_status(200)
      expect(body_as_json[:default_identity_id]).to eq "local:#{owner.account_id}"
      expect(body_as_json[:identities].size).to eq 1

      identity = body_as_json[:identities].first
      expect(identity).to include(
        id: "local:#{owner.account_id}",
        kind: 'local',
        provider: 'fedibird',
        authorization: 'ready'
      )
      expect(identity[:account]).to include(
        id: owner.account_id.to_s,
        acct: 'ada',
        display_name: 'Ada'
      )
      expect(identity[:account][:avatar]).to be_present
      expect(identity[:account][:avatar_static]).to be_present
      expect(identity[:capabilities]).to include(
        post: 'supported',
        media: 'supported',
        reply: 'supported',
        group: 'supported',
        schedule: 'supported'
      )
      expect(identity.keys).to contain_exactly(:id, :kind, :provider, :authorization, :capabilities, :account)
      expect(identity[:account].keys).to contain_exactly(:id, :acct, :display_name, :avatar, :avatar_static)

      body = response.body
      expect(body).not_to include(owner.email)
      expect(body).not_to match(/password|secret|credential|oauth|vault|token/i)
      expect(body).not_to include("local:#{other.account_id}")
    end

    it 'does not mark the identity ready when posting is disabled' do
      owner.settings.disable_post = true

      get :index

      identity = body_as_json[:identities].first
      expect(response).to have_http_status(200)
      expect(identity[:authorization]).to eq 'restricted'
      expect(identity[:capabilities][:post]).to eq 'unavailable'
      expect(identity[:capabilities][:media]).to eq 'unavailable'
    end

    it 'rejects an unauthenticated request' do
      allow(controller).to receive(:doorkeeper_token) { nil }

      get :index

      expect(response).to have_http_status(401)
    end

    it 'rejects a non-administrator' do
      member = Fabricate(:user)
      member_token = Fabricate(:accessible_access_token, resource_owner_id: member.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { member_token }

      get :index

      expect(response).to have_http_status(403)
    end

    it 'rejects a suspended account' do
      owner.account.update!(suspended_at: Time.now.utc)

      get :index

      expect(response).to have_http_status(403)
    end

    it 'rejects a disabled account' do
      owner.update!(disabled: true)

      get :index

      expect(response).to have_http_status(403)
    end
  end
end
