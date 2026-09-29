# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Fedibird viewer translation languages API' do
  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:personal_key) { "m2-viewer-#{SecureRandom.hex(8)}:fx" }

  around do |example|
    ClimateControl.modify(DEEPL_API_KEY: nil, DEEPL_PLAN: nil, LIBRE_TRANSLATE_ENDPOINT: nil, LIBRE_TRANSLATE_API_KEY: nil) do
      example.run
    end
  end

  before { Rails.cache.clear }

  def stub_personal_languages
    stub_request(:get, 'https://api-free.deepl.com/v2/languages?type=source').to_return(
      status: 200,
      body: Oj.dump([{ 'language' => 'EN' }, { 'language' => 'JA' }])
    )
    stub_request(:get, 'https://api-free.deepl.com/v2/languages?type=target').to_return(
      status: 200,
      body: Oj.dump([{ 'language' => 'JA' }])
    )
  end

  describe 'GET /api/v1/fedibird/translation_languages' do
    it 'requires an authenticated user' do
      get '/api/v1/fedibird/translation_languages'

      expect(response).to have_http_status(401)
    end

    it 'returns the personal language map without credential material' do
      with_vault_keyring do
        credential = store_vault_credential(owner: user, secret: personal_key)
        stub_personal_languages

        get '/api/v1/fedibird/translation_languages', headers: headers

        expect(response).to have_http_status(200)
        expect(response.headers['Cache-Control']).to include('no-store')
        expect(response.headers['Cache-Control']).not_to include('public')
        expect(body_as_json[:und]).to include('en', 'pt', 'ja')
        expect(body_as_json[:en]).to include('ja')
        expect(response.body).not_to include(personal_key, credential.binding_id, credential.encryption_key_id)
        cached = Rails.cache.read("v4:personal_translations/deepl/user/#{user.id}/credential/#{credential.id}/binding/#{credential.binding_id}/languages")
        expect(cached).to have_key(nil)
        expect(cached).not_to have_key('und')

        credential.update_column(:last_used_at, nil)
        WebMock.reset_executed_requests!
        get '/api/v1/fedibird/translation_languages', headers: headers

        expect(response).to have_http_status(200)
        expect(credential.reload.last_used_at).to be_nil
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'uses the instance provider when the viewer has no usable personal credential' do
      languages = { 'fr' => ['de'], nil => ['de'] }
      backend = instance_double(TranslationService::DeepL, languages: languages)
      allow(TranslationService).to receive(:configured?).and_return(true)
      allow(TranslationService).to receive(:configured).and_return(backend)
      allow(TranslationService).to receive(:for_user).and_call_original

      get '/api/v1/fedibird/translation_languages', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:fr]).to eq ['de']
      expect(body_as_json[:und]).to eq ['de']
      expect(Rails.cache.read('translation_service/languages')).to have_key(nil)
    end

    it 'does not fall back to the instance language map when personal DeepL fails' do
      with_vault_keyring do
        store_vault_credential(owner: user, secret: personal_key)
        store_vault_credential(owner: user, secret: "m2-second-#{SecureRandom.hex(4)}")
        allow(TranslationService).to receive(:configured).and_return('instance-languages')

        get '/api/v1/fedibird/translation_languages', headers: headers

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq({})
        expect(TranslationService).not_to have_received(:configured)
      end

      user.external_credentials.delete_all
      with_vault_keyring do
        store_vault_credential(owner: user, secret: personal_key)
        stub_request(:get, %r{https://api-free\.deepl\.com/v2/languages}).to_return(status: 500, body: personal_key)
        allow(TranslationService).to receive(:configured).and_raise('instance provider should not be called')

        get '/api/v1/fedibird/translation_languages', headers: headers

        expect(response).to have_http_status(503)
        expect(response.body).not_to include(personal_key)
      end
    end
  end

  describe 'GET /api/v1/instance/translation_languages' do
    it 'stays on the instance provider for an authenticated viewer with personal DeepL' do
      with_vault_keyring do
        store_vault_credential(owner: user, secret: personal_key)
      end

      get '/api/v1/instance/translation_languages', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(response.headers['Cache-Control']).to include('public')
      expect(response.body).not_to include(personal_key)
    end
  end
end
