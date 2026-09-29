# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal DeepL translation' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:personal_key) { "m2-personal-#{SecureRandom.hex(8)}" }
  let(:other_key) { "m2-other-#{SecureRandom.hex(8)}:fx" }
  let(:instance_key) { "m2-instance-#{SecureRandom.hex(8)}" }

  around do |example|
    ClimateControl.modify(DEEPL_API_KEY: nil, DEEPL_PLAN: nil, LIBRE_TRANSLATE_ENDPOINT: nil, LIBRE_TRANSLATE_API_KEY: nil, LIBRE_TRANSLATE_ALLOW_PRIVATE: nil) do
      example.run
    end
  end

  before do
    Rails.cache.clear
    stub_request(:get, %r{https://api\.deepl\.com/v2/languages}).to_return { |request| language_body(request) }
    stub_request(:get, %r{https://api-free\.deepl\.com/v2/languages}).to_return { |request| language_body(request) }
    stub_request(:post, 'https://api.deepl.com/v2/translate').to_return(status: 200, body: translation_body)
    stub_request(:post, 'https://api-free.deepl.com/v2/translate').to_return(status: 200, body: translation_body)
    stub_request(:any, /libre\.internal/).to_return(status: 200, body: Oj.dump([{ code: 'en', targets: ['ja'] }]))
  end

  def language_body(request)
    codes = request.uri.query.to_s.include?('target') ? [{ 'language' => 'JA' }] : [{ 'language' => 'EN' }, { 'language' => 'JA' }]
    { status: 200, body: Oj.dump(codes) }
  end

  def translation_body
    Oj.dump(translations: [{ text: '<p>こんにちは</p>', detected_source_language: 'EN' }])
  end

  def call_translation(status, viewer)
    TranslateStatusService.new.call(status, 'ja', user: viewer)
  end

  def cache_keys
    keys = []
    allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, key, *args, &block|
      keys << key
      method.call(key, *args, &block)
    end
    keys
  end

  it 'translates public and unlisted text for the owner and rejects private content without LibreTranslate' do
    with_vault_keyring do
      store_vault_credential(owner: user, secret: personal_key)
      ClimateControl.modify(LIBRE_TRANSLATE_ENDPOINT: 'http://libre.internal', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true', DEEPL_API_KEY: instance_key) do
        %w(public unlisted).each do |visibility|
          status = Fabricate(:status, text: "Hello #{visibility}", language: 'en', visibility: visibility)
          expect(call_translation(status, user).content).to include('こんにちは')
        end

        %w(private direct limited mutual personal).each do |visibility|
          status = Fabricate(:status, text: "Hidden #{visibility}", language: 'en', visibility: visibility)
          expect { call_translation(status, user) }.to raise_error(Mastodon::NotPermittedError)
        end

        expect(WebMock).to have_requested(:post, 'https://api.deepl.com/v2/translate').twice
        expect(WebMock).not_to have_requested(:any, /libre\.internal/)
        expect(WebMock).not_to have_requested(:any, /api-free\.deepl\.com/)
      end
    end
  end

  it 'uses only the viewer credential and isolates personal cache from other users and the instance' do
    with_vault_keyring do
      own = store_vault_credential(owner: user, secret: personal_key)
      theirs = store_vault_credential(owner: other, secret: other_key)
      status = Fabricate(:status, text: 'Hello shared', language: 'en', visibility: :public)
      keys = cache_keys

      ClimateControl.modify(DEEPL_API_KEY: instance_key, DEEPL_PLAN: 'free') do
        expect(call_translation(status, user).content).to include('こんにちは')
        expect(call_translation(status, other).content).to include('こんにちは')

        expect(WebMock).to have_requested(:post, 'https://api.deepl.com/v2/translate').with { |request|
          request.headers['Authorization'].to_s.include?(personal_key) && !request.body.to_s.include?(personal_key)
        }
        expect(WebMock).to have_requested(:post, 'https://api-free.deepl.com/v2/translate').with { |request|
          request.headers['Authorization'].to_s.include?(other_key)
        }
        expect(WebMock).not_to have_requested(:any, /deepl\.com/).with { |request|
          request.headers['Authorization'].to_s.include?(instance_key)
        }
        expect(keys.grep(/\Av3:translations\//)).to be_empty
        expect(keys).not_to include('translation_service/languages')
        expect(keys.join("\n")).to include("user/#{user.id}", "credential/#{own.id}", "binding/#{own.binding_id}")
        expect(keys.join("\n")).to include("user/#{other.id}", "credential/#{theirs.id}", "binding/#{theirs.binding_id}")
        expect(keys.join("\n")).not_to include(personal_key, other_key)
      end
    end
  end

  it 'does not update last_used_at on a personal cache hit' do
    with_vault_keyring do
      credential = store_vault_credential(owner: user, secret: personal_key)
      status = Fabricate(:status, text: 'Hello cache', language: 'en', visibility: :public)

      call_translation(status, user)
      expect(credential.reload.last_used_at).to be_present
      credential.update_column(:last_used_at, nil)
      WebMock.reset_executed_requests!

      call_translation(status, user)

      expect(credential.reload.last_used_at).to be_nil
      expect(WebMock).not_to have_requested(:any, /deepl\.com/)
    end
  end

  it 'changes the personal cache namespace on replace and keeps it across key rotation' do
    with_vault_keyring(primary: 'v1') do
      credential = store_vault_credential(owner: user, secret: personal_key)
      status = Fabricate(:status, text: 'Hello rotate', language: 'en', visibility: :public)
      call_translation(status, user)
      original_binding = credential.binding_id
      credential.update_column(:last_used_at, nil)

      with_vault_keyring(primary: 'v2') do
        UserCredentialVault.rotate_encryption_keys!
        credential.reload
        WebMock.reset_executed_requests!
        call_translation(status, user)

        expect(credential.binding_id).to eq original_binding
        expect(credential.reload.last_used_at).to be_nil
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end

      replacement = "m2-replaced-#{SecureRandom.hex(8)}"
      replace_vault_credential(owner: user, credential: credential, secret: replacement)
      credential.reload
      WebMock.reset_executed_requests!
      edited = Fabricate(:status, text: 'Hello replaced', language: 'en', visibility: :public)
      keys = cache_keys
      call_translation(edited, user)

      expect(credential.binding_id).not_to eq original_binding
      expect(keys.join("\n")).to include("binding/#{credential.binding_id}")
      expect(keys.join("\n")).not_to include("binding/#{original_binding}", replacement)
      expect(WebMock).to have_requested(:post, 'https://api.deepl.com/v2/translate').with { |request|
        request.headers['Authorization'].to_s.include?(replacement)
      }
    end
  end

  it 'falls back to the instance provider only when the personal credential is not usable yet' do
    with_vault_keyring do
      credential = store_vault_credential(owner: user, secret: personal_key)
      UserCredentialVault.revoke!(owner: user, credential: credential)
      status = Fabricate(:status, text: 'Hello fallback', language: 'en', visibility: :public)

      ClimateControl.modify(LIBRE_TRANSLATE_ENDPOINT: 'http://libre.internal') do
        backend = TranslationService::LibreTranslate.new('http://libre.internal', nil)
        allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
        allow(backend).to receive(:translate) do |texts, _source, _target|
          texts.map { |text| TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: 'LibreTranslate') }
        end
        allow(TranslationService).to receive(:configured).and_return(backend)

        expect(TranslationService.for_user(user)).to be backend
        expect(call_translation(status, user).content).to include('JA')
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end
  end

  it 'does not fall back after a personal provider was selected' do
    with_vault_keyring do
      store_vault_credential(owner: user, secret: personal_key)
      status = Fabricate(:status, text: 'Hello failure', language: 'en', visibility: :public)
      stub_request(:post, 'https://api.deepl.com/v2/translate').to_return(status: 429, body: personal_key)

      ClimateControl.modify(DEEPL_API_KEY: instance_key, LIBRE_TRANSLATE_ENDPOINT: 'http://libre.internal', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        expect { call_translation(status, user) }.to raise_error(TranslationService::TooManyRequestsError)
        expect(WebMock).not_to have_requested(:post, 'https://api-free.deepl.com/v2/translate')
        expect(WebMock).not_to have_requested(:any, /libre\.internal/)
      end

      store_vault_credential(owner: user, secret: "m2-second-#{SecureRandom.hex(4)}")
      WebMock.reset_executed_requests!
      expect { call_translation(status, user) }.to raise_error(Mastodon::NotPermittedError)
      expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      expect(WebMock).not_to have_requested(:any, /libre\.internal/)
    end
  end

  it 'does not let one viewer use another viewer credential' do
    with_vault_keyring do
      store_vault_credential(owner: other, secret: other_key)
      status = Fabricate(:status, text: 'Hello alone', language: 'en', visibility: :public)

      ClimateControl.modify(DEEPL_API_KEY: instance_key, DEEPL_PLAN: 'free') do
        allow(TranslationService).to receive(:configured).and_wrap_original do |original|
          backend = original.call
          allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
          allow(backend).to receive(:translate) do |texts, _source, _target|
            texts.map { |text| TranslationService::Translation.new(text: "INST #{text}", detected_source_language: 'en', provider: 'DeepL.com') }
          end
          backend
        end

        expect(call_translation(status, user).content).to include('INST')
        expect(WebMock).not_to have_requested(:any, /deepl\.com/).with { |request|
          request.headers['Authorization'].to_s.include?(other_key)
        }
      end
    end
  end
end
