# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Unauthenticated REST API access' do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read read:accounts') }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let!(:account) { Fabricate(:account, username: 'alice') }

  def cache_control
    response.headers['Cache-Control'].to_s
  end

  describe 'GET /api/v1/accounts/lookup' do
    context 'when AUTHORIZED_FETCH is enabled and anonymous REST access is allowed' do
      it 'publicly caches an anonymous lookup' do
        allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(false)

        ClimateControl.modify AUTHORIZED_FETCH: 'true', DISALLOW_UNAUTHENTICATED_API_ACCESS: nil do
          get '/api/v1/accounts/lookup', params: { acct: 'alice' }
        end

        expect(response).to have_http_status(200)
        expect(cache_control).to include('public', 'max-age=15')
        expect(response.headers['Vary']).to include('Authorization')
      end
    end

    context 'when DISALLOW_UNAUTHENTICATED_API_ACCESS is enabled' do
      it 'requires authentication for an anonymous lookup' do
        ClimateControl.modify DISALLOW_UNAUTHENTICATED_API_ACCESS: 'true' do
          get '/api/v1/accounts/lookup', params: { acct: 'alice' }
        end

        expect(response).to have_http_status(401)
        expect(cache_control).not_to include('public')
      end

      it 'allows an OAuth lookup' do
        ClimateControl.modify DISALLOW_UNAUTHENTICATED_API_ACCESS: 'true' do
          get '/api/v1/accounts/lookup', params: { acct: 'alice' }, headers: auth_headers
        end

        expect(response).to have_http_status(200)
      end
    end

    context 'when whitelist mode is enabled' do
      it 'requires authentication for an anonymous lookup' do
        allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(true)

        get '/api/v1/accounts/lookup', params: { acct: 'alice' }

        expect(response).to have_http_status(401)
      end
    end
  end

  describe 'GET /api/v1/custom_emojis' do
    it 'allows anonymous access when only AUTHORIZED_FETCH is enabled' do
      allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(false)

      ClimateControl.modify AUTHORIZED_FETCH: 'true', DISALLOW_UNAUTHENTICATED_API_ACCESS: nil do
        get '/api/v1/custom_emojis'
      end

      expect(response).to have_http_status(200)
    end

    it 'rejects anonymous access when DISALLOW_UNAUTHENTICATED_API_ACCESS is enabled' do
      ClimateControl.modify DISALLOW_UNAUTHENTICATED_API_ACCESS: 'true' do
        get '/api/v1/custom_emojis'
      end

      expect(response).to have_http_status(401)
    end
  end
end
