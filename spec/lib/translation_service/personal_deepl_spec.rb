# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TranslationService::PersonalDeepL do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:pro_key) { "m2-pro-#{SecureRandom.hex(8)}" }
  let(:free_key) { "m2-free-#{SecureRandom.hex(8)}:fx" }
  let(:instance_key) { "m2-instance-#{SecureRandom.hex(8)}" }

  around do |example|
    ClimateControl.modify(DEEPL_API_KEY: nil, DEEPL_PLAN: nil, LIBRE_TRANSLATE_ENDPOINT: nil, LIBRE_TRANSLATE_API_KEY: nil, LIBRE_TRANSLATE_ALLOW_PRIVATE: nil) do
      example.run
    end
  end

  before { Rails.cache.clear }

  def stub_deepl(host, status: 200, body: nil)
    payload = body || Oj.dump(translations: [{ text: 'Hello', detected_source_language: 'JA' }])
    stub_request(:post, "#{host}/v2/translate").to_return(status: status, body: payload)
    stub_request(:get, "#{host}/v2/languages?type=source").to_return(status: 200, body: Oj.dump([{ 'language' => 'EN' }, { 'language' => 'JA' }]))
    stub_request(:get, "#{host}/v2/languages?type=target").to_return(status: 200, body: Oj.dump([{ 'language' => 'JA' }]))
  end

  def authorization_header(request)
    value = request.headers['Authorization']
    value.is_a?(Array) ? value.join : value.to_s
  end

  def expect_personal_request(host, key)
    expect(WebMock).to have_requested(:post, "#{host}/v2/translate").with { |request|
      authorization_header(request) == "DeepL-Auth-Key #{key}" &&
        !request.uri.to_s.include?(key) &&
        !request.body.to_s.include?(key)
    }
  end

  def retained_key?(backend, key)
    backend.instance_variables.any? do |name|
      value = backend.instance_variable_get(name)
      (value.is_a?(String) && value.include?(key)) || value.is_a?(TranslationService::DeepL)
    end
  end

  it 'sends a :fx key to the free host and any other key to the pro host' do
    with_vault_keyring do
      free = store_vault_credential(owner: user, secret: free_key)
      pro = store_vault_credential(owner: other, secret: pro_key)
      stub_deepl('https://api-free.deepl.com')
      stub_deepl('https://api.deepl.com')

      ClimateControl.modify(DEEPL_PLAN: 'free', DEEPL_API_KEY: instance_key) do
        free_backend = described_class.resolve(user)
        pro_backend = described_class.resolve(other)

        expect(free_backend.translate(['こんにちは'], 'ja', 'en').first.text).to eq 'Hello'
        expect(pro_backend.translate(['こんにちは'], 'ja', 'en').first.text).to eq 'Hello'
        expect_personal_request('https://api-free.deepl.com', free_key)
        expect_personal_request('https://api.deepl.com', pro_key)
        expect(WebMock).not_to have_requested(:post, 'https://api-free.deepl.com/v2/translate').with { |request|
          authorization_header(request).include?(instance_key)
        }
        expect(retained_key?(free_backend, free_key)).to be false
        expect(retained_key?(pro_backend, pro_key)).to be false
        expect(free.binding_id).to eq free_backend.personal_languages_cache_key[%r{binding/([^/]+)}, 1]
      end
    end
  end

  it 'decrypts through the vault for translate and languages and drops the key' do
    with_vault_keyring do
      credential = store_vault_credential(owner: user, secret: pro_key)
      stub_deepl('https://api.deepl.com')
      allow(UserCredentialVault).to receive(:with_credential).and_call_original
      backend = described_class.resolve(user)
      log = StringIO.new
      previous = Rails.logger
      Rails.logger = Logger.new(log)

      result = backend.translate(['こんにちは'], 'ja', 'en')
      languages = backend.languages

      expect(result.first.provider).to eq 'DeepL.com'
      expect(languages['ja']).to include('en')
      expect(languages).to have_key(nil)
      expect(UserCredentialVault).to have_received(:with_credential).with(
        owner: user,
        credential: credential,
        provider: 'deepl',
        purpose: 'translation',
        credential_type: 'api_key'
      ).twice
      expect(retained_key?(backend, pro_key)).to be false
      expect(result.inspect).not_to include(pro_key)
      expect(languages.inspect).not_to include(pro_key)
      expect(log.string).not_to include(pro_key)
      expect(backend.personal_result_cache_key('ja', 'en', 'hash')).not_to include(pro_key)
      expect(backend.personal_languages_cache_key).to eq(
        "v4:personal_translations/deepl/user/#{user.id}/credential/#{credential.id}/binding/#{credential.binding_id}/languages"
      )
    ensure
      Rails.logger = previous
    end
  end

  it 'does not call the instance provider when personal DeepL fails' do
    with_vault_keyring do
      store_vault_credential(owner: user, secret: pro_key)
      stub_deepl('https://api.deepl.com', status: 403, body: "denied #{pro_key}")
      stub_deepl('https://api-free.deepl.com')
      stub_request(:any, /libre\.internal/)
      backend = described_class.resolve(user)

      ClimateControl.modify(DEEPL_API_KEY: instance_key, DEEPL_PLAN: 'free', LIBRE_TRANSLATE_ENDPOINT: 'http://libre.internal') do
        expect(TranslationService).not_to receive(:configured)

        expect { backend.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError) do |error|
          expect(error.message).not_to include(pro_key)
          expect(error.full_message).not_to include(pro_key)
        end

        stub_request(:post, 'https://api.deepl.com/v2/translate').to_return(status: 429, body: pro_key)
        expect { backend.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::TooManyRequestsError) { |error|
          expect(error.full_message).not_to include(pro_key)
        }

        stub_request(:post, 'https://api.deepl.com/v2/translate').to_return(status: 456, body: pro_key)
        expect { backend.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::QuotaExceededError)

        expect(WebMock).not_to have_requested(:any, /api-free\.deepl\.com/)
        expect(WebMock).not_to have_requested(:any, /libre\.internal/)
        expect(retained_key?(backend, pro_key)).to be false
      end
    end
  end

  it 'makes no DeepL request when the credential is revoked or deleted before the vault yields' do
    with_vault_keyring do
      revoked = store_vault_credential(owner: user, secret: pro_key)
      deleted = store_vault_credential(owner: other, secret: free_key)
      stub_deepl('https://api.deepl.com')
      stub_deepl('https://api-free.deepl.com')
      stub_request(:any, /libre\.internal/)
      revoked_backend = described_class.resolve(user)
      deleted_backend = described_class.resolve(other)
      UserCredentialVault.revoke!(owner: user, credential: revoked)
      UserCredentialVault.delete!(owner: other, credential: deleted)

      ClimateControl.modify(DEEPL_API_KEY: instance_key, LIBRE_TRANSLATE_ENDPOINT: 'http://libre.internal') do
        expect { revoked_backend.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)
        expect { deleted_backend.languages }.to raise_error(TranslationService::UnexpectedResponseError)
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
        expect(WebMock).not_to have_requested(:any, /libre\.internal/)
      end
    end
  end

  it 'uses the replaced secret and keeps the snapshotted cache scope' do
    with_vault_keyring do
      credential = store_vault_credential(owner: user, secret: free_key)
      backend = described_class.resolve(user)
      scope = backend.personal_languages_cache_key
      previous_binding = credential.binding_id
      replacement = "m2-replaced-#{SecureRandom.hex(8)}"
      replace_vault_credential(owner: user, credential: credential, secret: replacement)
      stub_deepl('https://api.deepl.com')
      stub_deepl('https://api-free.deepl.com')

      expect(backend.translate(['こんにちは'], 'ja', 'en').first.text).to eq 'Hello'

      expect_personal_request('https://api.deepl.com', replacement)
      expect(WebMock).not_to have_requested(:post, 'https://api-free.deepl.com/v2/translate')
      expect(backend.personal_languages_cache_key).to eq scope
      expect(scope).to include(previous_binding, "user/#{user.id}")
      fresh = described_class.resolve(user)
      expect(fresh.personal_languages_cache_key).not_to eq scope
      expect(fresh.personal_languages_cache_key).to include(credential.reload.binding_id)
    end
  end

  it 'does not cancel a DeepL request that already started' do
    with_vault_keyring do
      credential = store_vault_credential(owner: user, secret: pro_key)
      backend = described_class.resolve(user)
      stub_deepl('https://api.deepl.com')
      allow_any_instance_of(Request).to receive(:perform).and_wrap_original do |method, *args, &block|
        UserCredentialVault.revoke!(owner: user, credential: credential) if credential.reload.revoked_at.nil?
        method.call(*args, &block)
      end

      expect(backend.translate(['こんにちは'], 'ja', 'en').first.text).to eq 'Hello'
      expect(credential.reload.revoked_at).to be_present
      expect { backend.translate(['こんにちは'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)
      expect(WebMock).to have_requested(:post, 'https://api.deepl.com/v2/translate').once
    end
  end

  it 'keeps the cache scope across encryption-key rotation and changes it on replace' do
    with_vault_keyring(primary: 'v1') do
      credential = store_vault_credential(owner: user, secret: pro_key)
      before_key = described_class.resolve(user).personal_result_cache_key('en', 'ja', 'digest')
      binding_id = credential.binding_id

      with_vault_keyring(primary: 'v2') do
        UserCredentialVault.rotate_encryption_keys!
        credential.reload

        expect(credential.binding_id).to eq binding_id
        expect(credential.encryption_key_id).to eq 'v2'
        expect(described_class.resolve(user).personal_result_cache_key('en', 'ja', 'digest')).to eq before_key
      end

      replace_vault_credential(owner: user, credential: credential, secret: "m2-after-replace-#{SecureRandom.hex(4)}")
      credential.reload
      expect(credential.binding_id).not_to eq binding_id
      expect(described_class.resolve(user).personal_result_cache_key('en', 'ja', 'digest')).not_to eq before_key
    end
  end
end
