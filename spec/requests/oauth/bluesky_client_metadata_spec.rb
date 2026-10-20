# frozen_string_literal: true

require 'rails_helper'

describe 'Bluesky OAuth client metadata' do
  before { stub_webpacker_manifest }

  it 'stays unpublished until the instance signing key is configured' do
    get '/oauth/bluesky/client-metadata'
    expect(response).to have_http_status(:not_found)

    get '/oauth/bluesky/jwks'
    expect(response).to have_http_status(:not_found)
  end

  it 'publishes the metadata document and the public JWKS' do
    with_atproto_client do |key|
      get '/oauth/bluesky/client-metadata'
      document = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/json')
      expect(document['client_id']).to eq(ExternalBridge::Atproto::ClientDocument.client_id)
      expect(document['application_type']).to eq('web')
      expect(document['token_endpoint_auth_method']).to eq('private_key_jwt')
      expect(document['token_endpoint_auth_signing_alg']).to eq('ES256')
      expect(document['dpop_bound_access_tokens']).to be(true)
      expect(document['jwks_uri']).to eq("#{ExternalBridge::Atproto::ClientDocument.origin}/oauth/bluesky/jwks")
      expect(response.body).not_to include(key.to_pem)

      get '/oauth/bluesky/jwks'
      jwks = JSON.parse(response.body)
      expect(jwks['keys'].size).to eq(1)
      expect(jwks['keys'].first.keys).not_to include('d')
      expect(response.body).not_to include('PRIVATE')
    end
  end

  it 'rejects an authorization POST that has no CSRF token' do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    user = Fabricate(:user)
    sign_in user, scope: :user
    with_atproto_client do
      enable_atproto!(user)
      install_atproto_world!

      expect do
        post '/settings/external_services/bluesky/authorize', params: { account: AtprotoOauthHelper::HANDLE }
      end.not_to change(ExternalOauthAttempt, :count)
    end

    expect(response).to have_http_status(:unprocessable_entity)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
