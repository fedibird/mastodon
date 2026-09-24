# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'REST API cache headers' do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read read:accounts read:statuses read:follows') }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def cache_control
    response.headers['Cache-Control'].to_s
  end

  describe 'GET /api/v1/accounts/lookup' do
    let!(:account) { Fabricate(:account, username: 'alice') }

    it 'publicly caches an anonymous lookup and varies on Authorization' do
      get '/api/v1/accounts/lookup', params: { acct: 'alice' }

      expect(response).to have_http_status(200)
      expect(cache_control).to include('public', 'max-age=15', 'stale-while-revalidate=30', 'stale-if-error=86400')
      expect(response.headers['Vary']).to include('Authorization')
    end

    it 'does not publicly cache an authenticated lookup' do
      get '/api/v1/accounts/lookup', params: { acct: 'alice' }, headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).not_to include('public')
      expect(cache_control).to include('no-store')
    end
  end

  describe 'GET /api/v1/statuses/:id' do
    let(:status) { Fabricate(:status, visibility: :public) }

    it 'publicly caches an anonymous public status' do
      get "/api/v1/statuses/#{status.id}"

      expect(response).to have_http_status(200)
      expect(cache_control).to include('public', 'max-age=15')
      expect(response.headers['Vary']).to include('Authorization')
    end

    it 'does not publicly cache an authenticated status' do
      get "/api/v1/statuses/#{status.id}", headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).not_to include('public')
      expect(cache_control).to include('no-store')
    end
  end

  describe 'GET /api/v1/accounts/relationships' do
    let(:other) { Fabricate(:account) }

    it 'does not publicly cache a relationship lookup' do
      get '/api/v1/accounts/relationships', params: { 'id[]' => other.id }, headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).not_to include('public')
    end
  end

  describe 'GET /api/v1/custom_emojis' do
    it 'publicly caches even when authenticated' do
      get '/api/v1/custom_emojis', headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).to include('public', 'max-age=300', 'stale-while-revalidate=30', 'stale-if-error=86400')
    end

    it 'does not publicly cache in whitelist mode' do
      allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(true)

      get '/api/v1/custom_emojis', headers: auth_headers

      expect(cache_control).not_to include('public')
    end
  end

  describe 'GET /api/v1/instance/domain_blocks' do
    before do
      Fabricate(:domain_block, domain: 'evil.example', severity: :suspend)
    end

    it 'publicly caches when domain blocks are visible to everyone' do
      Setting.show_domain_blocks = 'all'

      get '/api/v1/instance/domain_blocks', headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).to include('public', 'max-age=300')
      expect(response.headers['Vary'].to_s).not_to include('Authorization')
    end

    it 'does not publicly cache a user-only domain block list for an authenticated request' do
      Setting.show_domain_blocks = 'users'

      get '/api/v1/instance/domain_blocks', headers: auth_headers

      expect(response).to have_http_status(200)
      expect(cache_control).not_to include('public')
      expect(response.headers['Vary']).to include('Authorization')
    end
  end
end
