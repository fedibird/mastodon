# frozen_string_literal: true

require 'rails_helper'

describe Settings::DeepLCredentialsController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:api_key) { 'personal-deepl-key-without-fx' }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    allow_any_instance_of(Webpacker::Manifest).to receive(:lookup!) do |*_args, **kwargs|
      kwargs[:with_integrity] ? ['/packs-test/dummy.js', nil] : '/packs-test/dummy.js'
    end
  end

  describe 'POST #create' do
    it 'does not accept an API key submitted with the password challenge' do
      expect do
        post :create, params: {
          api_key: api_key,
          form_challenge: { current_password: '123456789', return_to: "#{settings_external_credentials_path}?api_key=#{api_key}" },
        }
      end.not_to change(UserExternalCredential, :count)

      expect(response).to redirect_to(settings_external_credentials_path)
      expect(response.body).not_to include(api_key)
      expect(response.body).not_to include('form_challenge')
      expect(flash.to_hash.to_s).not_to include(api_key)
    end

    it 'does not mutate or render a challenge form when the challenge is missing' do
      expect(UserCredentialVault).not_to receive(:store!)
      expect(UserCredentialVault).not_to receive(:replace!)

      expect do
        post :create, params: { api_key: api_key, provider: 'libretranslate', purpose: 'login', credential_type: 'token', endpoint: 'https://evil.example' }
      end.not_to change(UserExternalCredential, :count)

      expect(response).to redirect_to(settings_external_credentials_path)
      expect(response).to have_http_status(:see_other)
      expect(response.location).not_to include(api_key)
      expect(response.body).not_to include(api_key)
      expect(response.body).not_to include('form_challenge')
      expect(flash.to_hash.to_s).not_to include(api_key)
    end

    it 'stores a server-fixed DeepL credential after a challenge and does not call DeepL or for_user' do
      with_vault_keyring do
        expect(TranslationService).not_to receive(:for_user)
        expect(UserCredentialVault).to receive(:store!).and_call_original

        post :create, params: {
          api_key: "  #{api_key}  ",
          provider: 'libretranslate',
          purpose: 'login',
          credential_type: 'token',
          endpoint: 'https://evil.example',
        }, session: challenge

        row = user.external_credentials.order(:id).last
        expect(response).to redirect_to(settings_external_credentials_path)
        expect(flash[:notice]).to eq(I18n.t('external_credentials.saved'))
        expect(flash[:notice]).not_to include(api_key)
        expect(response.location).not_to include(api_key)
        expect(row.provider).to eq('deepl')
        expect(row.purpose).to eq('translation')
        expect(row.credential_type).to eq('api_key')
        expect(probe_vault(owner: user, credential: row)[:result]).to eq(api_key)
        expect(WebMock).not_to have_requested(:any, /api\.deepl\.com/)
        expect(WebMock).not_to have_requested(:any, /api-free\.deepl\.com/)
      end
    end

    it 'selects PersonalDeepL after save and the instance provider after delete' do
      with_vault_keyring do
        ClimateControl.modify(DEEPL_API_KEY: 'instance-deepl-key', DEEPL_PLAN: 'free') do
          post :create, params: { api_key: api_key }, session: challenge
          expect(TranslationService.for_user(user)).to be_a(TranslationService::PersonalDeepL)

          row = user.external_credentials.order(:id).last
          delete :destroy, params: { id: row.id }, session: challenge

          expect(UserExternalCredential.find_by(id: row.id)).to be_nil
          expect(TranslationService.for_user(user)).to be_a(TranslationService::DeepL)
          expect(TranslationService.for_user(user)).not_to be_a(TranslationService::PersonalDeepL)
          expect(WebMock).not_to have_requested(:any, /deepl\.com/)
        end
      end
    end

    it 'replaces one row, changes binding_id, and clears revocation without calling DeepL' do
      with_vault_keyring do
        existing = store_vault_credential(owner: user, secret: 'old-personal-deepl-key')
        previous_binding = existing.binding_id
        existing.update!(revoked_at: 2.hours.ago, expires_at: 2.hours.ago)
        expect(UserCredentialVault).to receive(:replace!).and_call_original
        expect(TranslationService).not_to receive(:for_user)

        post :create, params: { api_key: api_key }, session: challenge

        existing.reload
        expect(user.external_credentials.count).to eq(1)
        expect(existing.binding_id).not_to eq(previous_binding)
        expect(existing.revoked_at).to be_nil
        expect(existing.expires_at).to be_nil
        expect(existing.provider).to eq('deepl')
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'redirects a persistence failure without echoing the secret or showing success' do
      with_vault_keyring do
        allow(UserCredentialVault).to receive(:store!).and_raise(ActiveRecord::RecordNotSaved.new("could not save #{api_key}"))

        post :create, params: { api_key: api_key }, session: challenge

        expect(response).to redirect_to(settings_external_credentials_path)
        expect(flash[:notice]).to be_nil
        expect(flash[:alert]).to eq(I18n.t('external_credentials.save_failed'))
        expect(flash[:alert]).not_to include(api_key)
        expect(response.location).not_to include(api_key)
        expect(response.body).not_to include(api_key)
        expect(user.external_credentials).to be_empty

        @controller = Settings::ExternalCredentialsController.new
        get :show, session: challenge
        field = Nokogiri::HTML(response.body).at_css('input[name="api_key"]')
        expect(field['value'].to_s).to eq('')
        expect(response.body).not_to include(api_key)
      end
    end

    it 'does not turn a statement error into the save-failed redirect' do
      with_vault_keyring do
        allow(UserCredentialVault).to receive(:store!).and_raise(ActiveRecord::StatementInvalid.new('syntax error'))

        expect do
          post :create, params: { api_key: api_key }, session: challenge
        end.to raise_error(ActiveRecord::StatementInvalid)

        expect(flash[:notice]).to be_nil
        expect(flash[:alert]).not_to eq(I18n.t('external_credentials.save_failed'))
        expect(user.external_credentials).to be_empty
      end
    end

    it 'redirects a replace lifecycle failure without echoing the secret or showing success' do
      with_vault_keyring do
        store_vault_credential(owner: user, secret: 'old-personal-deepl-key')
        allow(UserCredentialVault).to receive(:replace!).and_raise(UserCredentialVault::OwnerMismatch.new("owner mismatch #{api_key}"))

        post :create, params: { api_key: api_key }, session: challenge

        expect(response).to redirect_to(settings_external_credentials_path)
        expect(flash[:notice]).to be_nil
        expect(flash[:alert]).to eq(I18n.t('external_credentials.save_failed'))
        expect(flash[:alert]).not_to include(api_key)
        expect(response.location).not_to include(api_key)
        expect(response.body).not_to include(api_key)
        expect(user.external_credentials.count).to eq(1)

        @controller = Settings::ExternalCredentialsController.new
        get :show, session: challenge
        field = Nokogiri::HTML(response.body).at_css('input[name="api_key"]')
        expect(field['value'].to_s).to eq('')
        expect(response.body).not_to include(api_key)
        expect(response.body).not_to include('old-personal-deepl-key')
      end
    end

    it 'redirects a validation failure without echoing the secret' do
      secret = "zzsecretkeyzz\nmore"
      with_vault_keyring do
        post :create, params: { api_key: secret }, session: challenge
      end

      expect(response).to redirect_to(settings_external_credentials_path)
      expect(flash[:alert]).to eq(I18n.t('external_credentials.invalid_key'))
      expect(flash[:alert]).not_to include('zzsecretkeyzz')
      expect(response.location).not_to include('zzsecretkeyzz')
      expect(response.body).not_to include('zzsecretkeyzz')
      expect(user.external_credentials).to be_empty
    end

    it 'fails closed for duplicate rows' do
      with_vault_keyring do
        Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }
        expect(UserCredentialVault).not_to receive(:store!)
        expect(UserCredentialVault).not_to receive(:replace!)

        expect do
          post :create, params: { api_key: api_key }, session: challenge
        end.not_to change(UserExternalCredential, :count)

        expect(flash[:alert]).to eq(I18n.t('external_credentials.ambiguous'))
      end
    end

    it 'does not save when credential storage is unavailable' do
      with_vault_keyring(primary: '', keys: '') do
        post :create, params: { api_key: api_key }, session: challenge
      end

      expect(response).to redirect_to(settings_external_credentials_path)
      expect(flash[:alert]).to eq(I18n.t('external_credentials.storage_unavailable'))
      expect(flash[:alert]).not_to include('USER_EXTERNAL_CREDENTIAL')
      expect(user.external_credentials).to be_empty
    end

    it 'lets a user without a local password save' do
      passwordless = Fabricate(:user, external: true, password: nil)
      sign_in passwordless, scope: :user

      with_vault_keyring do
        post :create, params: { api_key: api_key }
        expect(passwordless.external_credentials.count).to eq(1)
      end
    end
  end

  describe 'DELETE #destroy' do
    it 'does nothing without a recent challenge' do
      row = with_vault_keyring { store_vault_credential(owner: user, secret: api_key) }

      expect do
        delete :destroy, params: { id: row.id, api_key: api_key }
      end.not_to change(UserExternalCredential, :count)

      expect(response).to redirect_to(settings_external_credentials_path)
      expect(response.body).not_to include(api_key)
      expect(response.body).not_to include('form_challenge')
    end

    it 'hard-deletes the scoped row without decrypting or calling DeepL' do
      with_vault_keyring do
        row = store_vault_credential(owner: user, secret: api_key)
        expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
        expect(UserCredentialVault).not_to receive(:with_credential)
        expect(TranslationService).not_to receive(:for_user)

        delete :destroy, params: { id: row.id }, session: challenge

        expect(response).to redirect_to(settings_external_credentials_path)
        expect(flash[:notice]).to eq(I18n.t('external_credentials.deleted'))
        expect(UserExternalCredential.find_by(id: row.id)).to be_nil
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'deletes a duplicate during repair' do
      with_vault_keyring do
        first, second = Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }

        delete :destroy, params: { id: first.id }, session: challenge

        expect(UserExternalCredential.find_by(id: first.id)).to be_nil
        expect(second.reload).to be_persisted
      end
    end

    it 'deletes when the keyring is missing and does not decrypt' do
      row = with_vault_keyring { store_vault_credential(owner: user, secret: api_key) }

      with_vault_keyring(primary: '', keys: '') do
        expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
        delete :destroy, params: { id: row.id }, session: challenge
      end

      expect(UserExternalCredential.find_by(id: row.id)).to be_nil
    end

    it 'does not delete another user credential or a different classification' do
      with_vault_keyring do
        other = store_vault_credential(owner: Fabricate(:user), secret: 'other-user-deepl-key')
        other_kind = store_vault_credential(owner: user, secret: 'github-token-value', provider: 'github', purpose: 'login', credential_type: 'token')

        delete :destroy, params: { id: other.id }, session: challenge
        expect(response).to have_http_status(404)
        expect(response.body).not_to include('other-user-deepl-key')
        expect(other.reload).to be_persisted

        delete :destroy, params: { id: other_kind.id }, session: challenge
        expect(response).to have_http_status(404)
        expect(other_kind.reload).to be_persisted
      end
    end
  end

  it 'keeps api_key filtered from logs' do
    expect(Rails.application.config.filter_parameters.map(&:to_s)).to include('api_key')
  end
end
