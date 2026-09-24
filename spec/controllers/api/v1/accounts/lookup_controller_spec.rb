# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Accounts::LookupController do
  render_views

  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:accounts') }
  let(:account) { Fabricate(:account, username: 'alice') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #show' do
    it 'returns the local account' do
      get :show, params: { acct: 'alice' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq account.id.to_s
      expect(body_as_json[:acct]).to eq 'alice'
    end

    it 'returns the account when the handle has surrounding spaces' do
      get :show, params: { acct: ' alice ' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq account.id.to_s
    end

    it 'returns the account when the handle has a leading @' do
      get :show, params: { acct: '@alice' }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq account.id.to_s
    end

    it 'returns http not found for a missing account' do
      get :show, params: { acct: 'missing' }

      expect(response).to have_http_status(404)
    end

    it 'returns http not found when account resolution raises an invalid URI error' do
      allow_any_instance_of(ResolveAccountService).to receive(:call).and_raise(Addressable::URI::InvalidURIError)

      get :show, params: { acct: 'alice' }

      expect(response).to have_http_status(404)
    end
  end
end
