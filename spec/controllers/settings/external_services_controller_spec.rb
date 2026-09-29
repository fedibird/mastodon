# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServicesController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:api_key) { 'personal-deepl-key-visible-check' }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    allow_any_instance_of(Webpacker::Manifest).to receive(:lookup!) do |*_args, **kwargs|
      kwargs[:with_integrity] ? ['/packs-test/dummy.js', nil] : '/packs-test/dummy.js'
    end
  end

  describe 'GET #index' do
    it 'asks for the password challenge and does not keep a query secret' do
      get :index, params: { api_key: api_key }

      field = Nokogiri::HTML(response.body).at_css('input[name="form_challenge[return_to]"]')
      expect(response).to have_http_status(200)
      expect(field['value']).to eq(settings_external_services_path)
      expect(response.body).not_to include(api_key)
      expect(response.body).not_to include('name="api_key"')
    end

    it 'renders the hub without a credential form' do
      with_vault_keyring do
        get :index, session: challenge
      end

      expect(response).to have_http_status(200)
      expect(response.body).to include('class="external-services"')
      expect(response.body).to include(I18n.t('external_services.add_service'))
      expect(response.body).to include(new_settings_external_service_path)
      expect(response.body).to include(I18n.t('external_services.empty'))
      expect(response.body).not_to include('name="api_key"')
    end

    it 'renders a configured DeepL card without secret material' do
      secret = 'personal-deepl-key-Q7z9'
      with_vault_keyring(primary: 'credkey', keys: "credkey:#{vault_key_material.fetch('v2')}") do
        row = store_vault_credential(owner: user, secret: secret)
        row.update!(last_used_at: Time.zone.parse('2024-01-02 03:04:05'))
        expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
        expect(UserCredentialVault).not_to receive(:with_credential)

        get :index, session: challenge

        expect(response.body).to include(I18n.t('external_services.providers.deepl.name'))
        expect(response.body).to include(I18n.t('external_services.providers.deepl.subtitle'))
        expect(response.body).to include(I18n.t('external_services.status.connected'))
        expect(response.body).to include(I18n.t('external_credentials.last_used'))
        expect(response.body).to include(settings_external_services_deepl_path)
        expect(response.body).to include('external-services__grid')
        expect(response.body).to include('external-service-card')
        expect(response.body).to include('aria-hidden="true"')
        expect(response.body).to include('alt=""')
        expect(response.body).not_to include('verified')
        expect(response.body).not_to include('Verified')
        expect(response.body).not_to include(secret)
        expect(response.body).not_to include('Q7z9')
        expect(response.body).not_to include(row.encrypted_payload)
        expect(response.body).not_to include(row.binding_id)
        expect(response.body).not_to include(row.encryption_key_id)
        expect(response.body).not_to include('credkey')
        expect(response.body).not_to include('name="api_key"')
        expect(response.body).not_to include(I18n.t('external_credentials.delete'))
      end
    end

    it 'keeps one card when several DeepL rows exist' do
      with_vault_keyring do
        Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }

        get :index, session: challenge
      end

      document = Nokogiri::HTML(response.body)
      expect(document.css('article.external-service-card').size).to eq(1)
      expect(response.body).to include(I18n.t('external_services.status.warning'))
      expect(response.body).not_to include('name="api_key"')
    end
  end

  describe 'GET #new' do
    it 'asks for the password challenge on the catalog path' do
      get :new, params: { api_key: api_key }

      field = Nokogiri::HTML(response.body).at_css('input[name="form_challenge[return_to]"]')
      expect(field['value']).to eq(new_settings_external_service_path)
      expect(response.body).not_to include(api_key)
    end

    it 'lists only DeepL and links Add to the DeepL page' do
      with_vault_keyring do
        get :new, session: challenge
      end

      document = Nokogiri::HTML(response.body)
      expect(document.css('article.external-service-card').size).to eq(1)
      expect(response.body).to include(I18n.t('external_services.providers.deepl.description'))
      expect(response.body).to include(settings_external_services_deepl_path)
      expect(response.body).to include(I18n.t('external_services.add'))
      expect(response.body).not_to include('Misskey')
      expect(response.body).not_to include('PeerTube')
      expect(response.body).not_to include('Bluesky')
      expect(ExternalServices::Registry.providers).to eq([ExternalServices::DeepL])
    end

    it 'links a configured or duplicate DeepL connection to Manage' do
      with_vault_keyring do
        Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }

        get :new, session: challenge
      end

      expect(response.body).to include(I18n.t('external_services.manage'))
      expect(response.body).to include(I18n.t('external_services.status.warning'))
      expect(response.body).to include(settings_external_services_deepl_path)
      expect(response.body).not_to include('name="api_key"')
    end
  end
end
