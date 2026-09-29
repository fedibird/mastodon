# frozen_string_literal: true

require 'rails_helper'

describe 'external services compatibility routes' do
  let(:secret) { 'compat-deepl-secret-value' }

  it 'redirects the old settings path without copying the query string' do
    get '/settings/external_credentials', params: { api_key: secret }

    expect(response).to have_http_status(302)
    expect(response).to redirect_to('/settings/external_services')
    expect(response.location).not_to include(secret)
    expect(response.location).not_to include('api_key')
    expect(response.body).not_to include(secret)
  end

  it 'redirects an old create without storing the secret or putting it in the URL' do
    expect do
      post '/settings/deepl_credentials', params: { api_key: secret, provider: 'libretranslate', purpose: 'login', credential_type: 'token' }
    end.not_to change(UserExternalCredential, :count)

    expect(response).to have_http_status(303)
    expect(response).to redirect_to('/settings/external_services/deepl')
    expect(response.location).not_to include(secret)
    expect(response.location).not_to include('api_key')
    expect(response.location).not_to include('libretranslate')
    expect(response.body).not_to include(secret)
  end

  it 'redirects an old delete without deleting or copying the secret' do
    user = Fabricate(:user)
    row = with_vault_keyring { store_vault_credential(owner: user, secret: secret) }

    delete "/settings/deepl_credentials/#{row.id}", params: { api_key: secret }

    expect(response).to have_http_status(303)
    expect(response).to redirect_to('/settings/external_services/deepl')
    expect(response.location).not_to include(secret)
    expect(response.body).not_to include(secret)
    expect(row.reload).to be_persisted
  end

  it 'has no generic provider mutation route' do
    route = Rails.application.routes.recognize_path('/settings/external_services/mastodon', method: :post)
    expect(route).to include(controller: 'application', action: 'raise_not_found')

    paths = Rails.application.routes.routes.map { |entry| entry.path.spec.to_s }
    expect(paths).not_to include(a_string_matching(%r{/settings/external_services/:provider}))
  end
end
