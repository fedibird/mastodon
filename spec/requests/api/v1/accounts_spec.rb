# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Accounts' do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'read:accounts' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' } }

  describe 'GET /api/v1/accounts' do
    let!(:account)       { Fabricate(:user).account }
    let!(:other_account) { Fabricate(:user).account }

    it 'returns the requested accounts for id[] and omits missing ids', :aggregate_failures do
      get '/api/v1/accounts', params: { id: [account.id, other_account.id, 999_999] }, headers: headers

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(account_ids_from_body).to contain_exactly(account.id.to_s, other_account.id.to_s)
    end

    it 'keeps accepting the legacy ids[] parameter' do
      get '/api/v1/accounts', params: { ids: [account.id, other_account.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(account_ids_from_body).to contain_exactly(account.id.to_s, other_account.id.to_s)
    end

    it 'unions id[] and ids[] and returns each account once' do
      get '/api/v1/accounts', params: { id: [account.id], ids: [account.id, other_account.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(account_ids_from_body).to contain_exactly(account.id.to_s, other_account.id.to_s)
    end

    it 'returns an empty list when no ids are given' do
      get '/api/v1/accounts', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq []
    end

    it 'omits pending and unconfirmed local accounts and keeps remote accounts', :aggregate_failures do
      pending = Fabricate(:user)
      pending.update_columns(approved: false)
      unconfirmed = Fabricate(:user)
      unconfirmed.update_columns(confirmed_at: nil)
      remote = Fabricate(:account, username: 'remote', domain: 'example.com', protocol: :activitypub, inbox_url: 'https://example.com/users/remote/inbox')

      get '/api/v1/accounts', params: { id: [account.id, pending.account_id, unconfirmed.account_id, remote.id] }, headers: headers

      expect(response).to have_http_status(200)
      expect(account_ids_from_body).to contain_exactly(account.id.to_s, remote.id.to_s)
    end

    context 'without a token' do
      let(:headers) { { 'Accept' => 'application/json' } }

      it 'returns the requested accounts' do
        get '/api/v1/accounts', params: { id: [account.id] }, headers: headers

        expect(response).to have_http_status(200)
        expect(account_ids_from_body).to contain_exactly(account.id.to_s)
      end
    end

    context 'with the read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        get '/api/v1/accounts', params: { id: [account.id] }, headers: headers

        expect(response).to have_http_status(200)
      end
    end

    context 'with a write-only token' do
      let(:scopes) { 'write:accounts' }

      it 'returns http forbidden' do
        get '/api/v1/accounts', params: { id: [account.id] }, headers: headers

        expect(response).to have_http_status(403)
        expect(response.content_type).to start_with('application/json')
      end
    end

    context 'with the profile scope' do
      let(:scopes) { 'profile' }

      it 'returns http forbidden' do
        get '/api/v1/accounts', params: { id: [account.id] }, headers: headers

        expect(response).to have_http_status(403)
      end
    end

    context 'when the unique id count is limited' do
      before do
        stub_const('Api::BaseController::DEFAULT_ACCOUNTS_LIMIT', 2)
      end

      it 'accepts two unique ids' do
        get '/api/v1/accounts', params: { id: [account.id, other_account.id] }, headers: headers

        expect(response).to have_http_status(200)
      end

      it 'rejects three unique ids' do
        extra = Fabricate(:user).account

        get '/api/v1/accounts', params: { id: [account.id, other_account.id, extra.id] }, headers: headers

        expect(response).to have_http_status(422)
        expect(response.content_type).to start_with('application/json')
      end

      it 'counts ids after removing duplicates' do
        get '/api/v1/accounts', params: { id: [account.id, account.id], ids: [other_account.id] }, headers: headers

        expect(response).to have_http_status(200)
        expect(account_ids_from_body).to contain_exactly(account.id.to_s, other_account.id.to_s)
      end
    end
  end

  describe 'POST /api/v1/accounts/:id/follow' do
    let(:scopes) { 'write:follows' }

    it 'rejects following your own account', :aggregate_failures do
      expect do
        post "/api/v1/accounts/#{user.account.id}/follow", headers: headers
      end.to not_change(Follow, :count).and not_change(FollowRequest, :count)

      expect(response).to have_http_status(403)
      expect(response.content_type).to start_with('application/json')
      expect(body_as_json.keys).to eq %i(error)
      expect(body_as_json[:error]).to eq 'Following your own account is not allowed'
    end

    it 'returns the Japanese self-follow error' do
      post "/api/v1/accounts/#{user.account.id}/follow", headers: headers.merge('Accept-Language' => 'ja')

      expect(response).to have_http_status(403)
      expect(body_as_json[:error]).to eq '自分のアカウントをフォローすることはできません'
    end

    context 'with the read:accounts scope' do
      let(:scopes) { 'read:accounts' }

      it 'rejects the request before the self-follow check' do
        post "/api/v1/accounts/#{user.account.id}/follow", headers: headers

        expect(response).to have_http_status(403)
        expect(body_as_json[:error]).to eq 'This action is outside the authorized scopes'
      end
    end

    it 'follows an unlocked account' do
      target = Fabricate(:user).account

      post "/api/v1/accounts/#{target.id}/follow", headers: headers

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(body_as_json[:following]).to be true
      expect(body_as_json[:requested]).to be false
      expect(user.account.following?(target)).to be true
    end

    it 'requests to follow a locked account' do
      target = Fabricate(:user, account: Fabricate(:account, locked: true)).account

      post "/api/v1/accounts/#{target.id}/follow", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:following]).to be false
      expect(body_as_json[:requested]).to be true
      expect(user.account.requested?(target)).to be true
    end
  end

  def account_ids_from_body
    body_as_json.map { |account| account[:id] }
  end
end
