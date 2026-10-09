# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PostingIdentitiesController do # rubocop:disable Metrics/BlockLength
  render_views

  let(:owner) { user_with_role('Owner') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read') }

  before do
    owner.account.update!(username: 'sender', display_name: 'Sender')
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def nested_keys(value)
    case value
    when Hash
      value.keys.map(&:to_s) + value.values.flat_map { |item| nested_keys(item) }
    when Array
      value.flat_map { |item| nested_keys(item) }
    else
      []
    end
  end

  describe 'GET #index' do # rubocop:disable Metrics/BlockLength
    it 'returns only the signed-in local identity' do
      other = Fabricate(:account, username: 'someoneelse', display_name: 'Someone Else')

      get :index

      identity = body_as_json[:identities].first

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(:default_identity_id, :identities)
      expect(body_as_json[:default_identity_id]).to eq "local:#{owner.account.id}"
      expect(body_as_json[:identities].size).to eq 1
      expect(identity.keys).to contain_exactly(:id, :kind, :provider, :account, :authorization, :capabilities)
      expect(identity).to include(id: "local:#{owner.account.id}", kind: 'local', provider: 'fedibird', authorization: 'ready')
      expect(identity[:account].keys).to contain_exactly(:id, :acct, :display_name, :avatar, :avatar_static)
      expect(identity[:account]).to include(id: owner.account.id.to_s, acct: 'sender', display_name: 'Sender')
      expect(identity[:account][:id]).not_to eq other.id.to_s
      expect(identity[:capabilities]).to eq(
        post: 'supported',
        media: 'supported',
        reply: 'supported',
        group: 'supported',
        schedule: 'supported'
      )
      expect(nested_keys(body_as_json)).not_to include('token', 'secret', 'password', 'credential', 'oauth_token', 'email', 'private_key')
      expect(response.body).not_to include(owner.email)
      expect(response.body).not_to include(other.username)
    end

    it 'does not mark the identity ready while posting is disabled' do
      owner.settings.disable_post = true

      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json[:identities].first[:authorization]).to eq 'unavailable'
      expect(body_as_json[:identities].first[:capabilities].values).to all(eq 'unavailable')
    end

    it 'rejects an account id even when it names the signed-in account' do
      get :index, params: { account_id: owner.account.id }

      expect(response).to have_http_status(403)
    end

    it 'rejects another account id' do
      other = Fabricate(:account)

      get :index, params: { account_id: other.id }

      expect(response).to have_http_status(403)
      expect(response.body).not_to include(other.username)
    end

    it 'rejects a missing token' do
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

    it 'rejects a write-only token' do
      write_token = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'write')
      allow(controller).to receive(:doorkeeper_token) { write_token }

      get :index

      expect(response).to have_http_status(403)
    end

    it 'does not offer a suspended or disabled account as a ready sender' do
      owner.account.update!(suspended_at: Time.now.utc)

      get :index

      expect(response).to have_http_status(403)

      owner.account.update!(suspended_at: nil)
      owner.disable!

      get :index

      expect(response).to have_http_status(403)
      expect(PostingIdentity::Local.build(owner).authorization).to eq 'unavailable'
    end
  end
end
