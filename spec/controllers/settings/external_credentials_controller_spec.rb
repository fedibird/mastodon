# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalCredentialsController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:api_key) { 'personal-deepl-key-visible-check' }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  def key_field(body)
    Nokogiri::HTML(body).at_css('input[name="api_key"]')
  end

  before do
    sign_in user, scope: :user
    allow_any_instance_of(Webpacker::Manifest).to receive(:lookup!) do |*_args, **kwargs|
      kwargs[:with_integrity] ? ['/packs-test/dummy.js', nil] : '/packs-test/dummy.js'
    end
  end

  describe 'GET #show' do
    it 'asks for the password challenge and does not keep a query secret' do
      get :show, params: { api_key: api_key }

      field = Nokogiri::HTML(response.body).at_css('input[name="form_challenge[return_to]"]')
      expect(response).to have_http_status(200)
      expect(field['value']).to eq(settings_external_credentials_path)
      expect(response.body).not_to include(api_key)
      expect(response.body).not_to include('name="api_key"')
    end

    it 'renders an empty secret field after a recent challenge' do
      with_vault_keyring do
        get :show, session: challenge

        field = key_field(response.body)
        expect(response).to have_http_status(200)
        expect(field['type']).to eq('password')
        expect(field['value'].to_s).to eq('')
        expect(field['autocomplete']).to eq('new-password')
        expect(field['spellcheck']).to eq('false')
        expect(field['autocapitalize']).to eq('none')
        expect(response.body).to include(I18n.t('external_credentials.save'))
        expect(response.body).to include('Saving does not contact DeepL')
        expect(response.body).to include('used ahead of this server')
        expect(response.body).to include('does not silently switch')
        expect(response.body).to include('vault encryption keys can decrypt')
      end
    end

    it 'keeps the field empty when a credential is configured and does not render secret material' do
      secret = 'personal-deepl-key-Q7z9'
      with_vault_keyring(primary: 'credkey', keys: "credkey:#{vault_key_material.fetch('v2')}") do
        row = store_vault_credential(owner: user, secret: secret)
        row.update!(last_used_at: Time.zone.parse('2024-01-02 03:04:05'))

        get :show, session: challenge

        field = key_field(response.body)
        expect(field['value'].to_s).to eq('')
        expect(response.body).to include(I18n.t('external_credentials.configured'))
        expect(response.body).to include(I18n.t('external_credentials.replace'))
        expect(response.body).to include(I18n.t('external_credentials.last_used'))
        expect(response.body).not_to include(secret)
        expect(response.body).not_to include('Q7z9')
        expect(response.body).not_to include(row.encrypted_payload)
        expect(response.body).not_to include(row.binding_id)
        expect(response.body).not_to include('credkey')
      end
    end

    it 'renders Japanese copy for a Japanese user' do
      user.update!(locale: 'ja')

      with_vault_keyring do
        get :show, session: challenge
      end

      expect(response.body).to include('外部サービス')
      expect(response.body).to include('個人のDeepL APIキー')
      expect(response.body).to include('このAPIキーは暗号化して保存され、あなた自身の翻訳リクエストにのみ使用されます。')
      expect(response.body).to include('サーバーは翻訳実行時にAPIキーを復号します。エンドツーエンド暗号化ではありません。')
      expect(response.body).to include('DeepLの利用料金・利用上限はあなた自身の契約に従います。')
      expect(response.body).to include('保存したAPIキーを再表示することはできません。差し替える場合は新しいAPIキーを入力してください。')
      expect(response.body).to include('保存時にはDeepLへの接続確認を行いません。')
      expect(response.body).to include('現在、個人DeepLでは公開・未収載の投稿だけを翻訳します。')
      expect(response.body).to include('個人APIキーを削除すると、利用可能な場合はサーバー側の翻訳サービスに戻ります。')
      expect(response.body).to include('このサーバーの翻訳サービスより優先して使われます。')
      expect(response.body).to include('サーバー側の翻訳サービスへ自動的には切り替えません。')
      expect(response.body).to include('データベースと保管用の暗号鍵の両方を読めるサーバー管理者は、このAPIキーを復号できます。')
    end

    it 'shows metadata and delete without a save form when several credentials exist' do
      with_vault_keyring do
        rows = Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }
        revoked = rows.first
        revoked.update!(revoked_at: 1.day.ago)

        get :show, session: challenge

        expect(response.body).to include(I18n.t('external_credentials.ambiguous'))
        expect(response.body).to include(I18n.t('external_credentials.revoked'))
        expect(key_field(response.body)).to be_nil
        expect(response.body).not_to include(rows.first.binding_id)
        expect(response.body).not_to include(rows.second.encrypted_payload)
        expect(response.body.scan('deepl_credential').size).to be >= 2
      end
    end

    it 'renders the empty state when the vault is unavailable' do
      with_vault_keyring(primary: '', keys: '') do
        get :show, session: challenge
      end

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('external_credentials.storage_unavailable'))
      expect(response.body).not_to include('user external credential keyring')
      expect(key_field(response.body)).to be_nil
    end

    it 'still renders when the vault is unavailable and allows delete only' do
      row = with_vault_keyring { store_vault_credential(owner: user, secret: api_key) }

      with_vault_keyring(primary: '', keys: '') do
        get :show, session: challenge
      end

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('external_credentials.storage_unavailable'))
      expect(response.body).not_to include('user external credential keyring')
      expect(response.body).to include(I18n.t('external_credentials.configured'))
      expect(response.body).to include(settings_deepl_credential_path(row))
      expect(key_field(response.body)).to be_nil
      expect(response.body).not_to include(api_key)
    end

    it 'skips the challenge when the user has no local password' do
      passwordless = Fabricate(:user, external: true, password: nil)
      sign_in passwordless, scope: :user

      with_vault_keyring do
        get :show
      end

      expect(key_field(response.body)['value'].to_s).to eq('')
    end
  end
end
