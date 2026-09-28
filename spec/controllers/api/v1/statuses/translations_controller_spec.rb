# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::TranslationsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:statuses' }
  let(:status) { Fabricate(:status, text: 'Hello', language: 'en', visibility: :public) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(I18n).to receive(:locale).and_return(:ja)
  end

  describe 'POST #create' do
    it 'returns the translation' do
      translation = Translation.new(
        status: status,
        content: '<p>こんにちは</p>',
        spoiler_text: '',
        detected_source_language: 'en',
        language: 'ja',
        provider: 'DeepL.com',
        poll_options: [],
        media_attachments: []
      )
      allow(TranslateStatusService).to receive_message_chain(:new, :call).and_return(translation)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:content]).to eq '<p>こんにちは</p>'
      expect(body_as_json[:language]).to eq 'ja'
      expect(body_as_json[:provider]).to eq 'DeepL.com'
      expect(body_as_json[:detected_source_language]).to eq 'en'
    end

    it 'returns 404 for a status the user cannot see' do
      hidden = Fabricate(:status, visibility: :direct)

      post :create, params: { status_id: hidden.id }

      expect(response).to have_http_status(404)
    end

    context 'when the selected provider allows private content' do
      let(:backend) { instance_double(TranslationService::LibreTranslate) }

      before do
        allow(TranslationService).to receive(:configured?).and_return(true)
        allow(TranslationService).to receive(:configured).and_return(backend)
        allow(backend).to receive(:private_content_allowed?).and_return(true)
        allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
        allow(backend).to receive(:translate) do |texts, _source, _target|
          texts.map do |text|
            TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: 'LibreTranslate')
          end
        end
        Rails.cache.clear
      end

      it 'returns 404 for private and direct statuses the user cannot see' do
        private_status = Fabricate(:status, visibility: :private, text: 'Secret', language: 'en')
        direct_status = Fabricate(:status, visibility: :direct, text: 'Secret', language: 'en')

        post :create, params: { status_id: private_status.id }
        expect(response).to have_http_status(404)

        post :create, params: { status_id: direct_status.id }
        expect(response).to have_http_status(404)
        expect(backend).not_to have_received(:translate)
      end

      it 'translates private and direct statuses the user is allowed to view' do
        owned_private = Fabricate(:status, account: user.account, visibility: :private, text: 'Hello private', language: 'en')
        mentioned_direct = Fabricate(:status, visibility: :direct, text: 'Hello direct', language: 'en')
        Fabricate(:mention, account: user.account, status: mentioned_direct)

        post :create, params: { status_id: owned_private.id }
        expect(response).to have_http_status(200)
        expect(body_as_json[:provider]).to eq 'LibreTranslate'

        post :create, params: { status_id: mentioned_direct.id }
        expect(response).to have_http_status(200)
        expect(backend).to have_received(:translate).twice
      end

      it 'returns 404 for a limited status unless the user is a mention recipient' do
        hidden = Fabricate(:status, visibility: :limited, text: 'Secret limited', language: 'en')
        hidden.mentions.create!(account: Fabricate(:account), silent: true)
        visible = Fabricate(:status, visibility: :limited, text: 'Hello limited', language: 'en')
        visible.mentions.create!(account: user.account, silent: true)

        post :create, params: { status_id: hidden.id }
        expect(response).to have_http_status(404)
        expect(backend).not_to have_received(:translate)

        post :create, params: { status_id: visible.id }
        expect(response).to have_http_status(200)
        expect(body_as_json[:provider]).to eq 'LibreTranslate'
        expect(backend).to have_received(:translate).once
      end

      it 'translates a personal status for its owner and returns 404 for anyone else' do
        hidden = Fabricate(:status, visibility: :personal, text: 'Secret personal', language: 'en')
        owned = Fabricate(:status, account: user.account, visibility: :personal, text: 'Hello personal', language: 'en')

        post :create, params: { status_id: hidden.id }
        expect(response).to have_http_status(404)
        expect(backend).not_to have_received(:translate)

        post :create, params: { status_id: owned.id }
        expect(response).to have_http_status(200)
        expect(body_as_json[:provider]).to eq 'LibreTranslate'
        expect(backend).to have_received(:translate).once
      end
    end

    it 'does not let a request parameter or the LibreTranslate flag send an owned private status to DeepL' do
      backend = TranslationService::DeepL.new('free', 'deepl-secret')
      allow(TranslationService).to receive(:configured?).and_return(true)
      allow(TranslationService).to receive(:configured).and_return(backend)
      allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
      allow(backend).to receive(:translate)
      Rails.cache.clear

      owned = Fabricate(:status, account: user.account, visibility: :private, text: 'Hello', language: 'en')

      ClimateControl.modify(LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        post :create, params: { status_id: owned.id, allow_private: 'true', trusted: 'true' }
      end

      expect(response).to have_http_status(403)
      expect(backend).not_to have_received(:translate)
      expect(backend.private_content_allowed?).to be false
    end

    it 'returns 403 when no translation provider is configured' do
      allow(TranslationService).to receive(:configured?).and_return(false)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(403)
    end

    it 'returns 404 when NotConfiguredError is raised after configuration' do
      allow(TranslateStatusService).to receive_message_chain(:new, :call).and_raise(TranslationService::NotConfiguredError)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(404)
    end

    it 'returns 503 for quota, rate limit, and provider failure' do
      service = instance_double(TranslateStatusService)
      allow(TranslateStatusService).to receive(:new).and_return(service)

      allow(service).to receive(:call).and_raise(TranslationService::QuotaExceededError)
      post :create, params: { status_id: status.id }
      expect(response).to have_http_status(503)
      expect(body_as_json[:error]).to be_present

      allow(service).to receive(:call).and_raise(TranslationService::TooManyRequestsError)
      post :create, params: { status_id: status.id }
      expect(response).to have_http_status(503)

      allow(service).to receive(:call).and_raise(TranslationService::UnexpectedResponseError)
      post :create, params: { status_id: status.id }
      expect(response).to have_http_status(503)
    end

    it 'rejects a missing token' do
      allow(controller).to receive(:doorkeeper_token).and_return(nil)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(401)
    end

    it 'keeps the legacy call when source and target are omitted' do
      service = instance_double(TranslateStatusService, call: Translation.new(status: status, content: 'x', language: 'ja', provider: 'DeepL.com'))
      allow(TranslateStatusService).to receive(:new).and_return(service)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(200)
      expect(service).to have_received(:call).with(status, 'ja')
    end

    it 'passes one or both explicit languages and leaves the other on the legacy path' do
      service = instance_double(TranslateStatusService, call: Translation.new(status: status, content: 'x', language: 'de', provider: 'DeepL.com'))
      allow(TranslateStatusService).to receive(:new).and_return(service)

      post :create, params: { status_id: status.id, source_language: 'en', target_language: 'de' }
      expect(service).to have_received(:call).with(status, 'de', source_language: 'en', explicit_source: true, explicit_target: true)

      post :create, params: { status_id: status.id, target_language: 'de' }
      expect(service).to have_received(:call).with(status, 'de', source_language: nil, explicit_source: false, explicit_target: true)

      post :create, params: { status_id: status.id, source_language: 'zh-Hans' }
      expect(service).to have_received(:call).with(status, 'ja', source_language: 'zh-Hans', explicit_source: true, explicit_target: false)
    end

    context 'with an explicit language pair' do
      let(:backend) { instance_double(TranslationService::DeepL) }

      before do
        allow(TranslationService).to receive(:configured?).and_return(true)
        allow(TranslationService).to receive(:configured).and_return(backend)
        allow(backend).to receive(:private_content_allowed?).and_return(false)
        allow(backend).to receive(:languages).and_return('en' => ['ja'], 'zh-Hans' => ['ja'], 'zh-Hant' => ['ja'], nil => ['ja'])
        allow(backend).to receive(:translate) do |texts, source, _target|
          texts.map do |text|
            TranslationService::Translation.new(text: "JA #{text}", detected_source_language: source || 'en', provider: 'DeepL.com')
          end
        end
        Rails.cache.clear
      end

      it 'translates und as provider auto detection and keeps exact Chinese script tags' do
        post :create, params: { status_id: status.id, source_language: 'und', target_language: 'ja' }
        expect(response).to have_http_status(200)
        expect(backend).to have_received(:translate).with(anything, nil, 'ja')

        post :create, params: { status_id: status.id, source_language: 'zh-Hant', target_language: 'ja' }
        expect(response).to have_http_status(200)
        expect(backend).to have_received(:translate).with(anything, 'zh-Hant', 'ja')
        expect(status.reload.language).to eq 'en'
      end

      it 'returns 422 for an unsupported explicit pair' do
        post :create, params: { status_id: status.id, source_language: 'fr', target_language: 'de' }

        expect(response).to have_http_status(422)
        expect(body_as_json[:error]).to eq 'This language pair is not supported by the translation service.'
        expect(backend).not_to have_received(:translate)
      end

      it 'keeps hidden and private statuses unauthorized when languages are explicit' do
        hidden = Fabricate(:status, visibility: :direct, text: 'Secret', language: 'en')
        owned = Fabricate(:status, account: user.account, visibility: :private, text: 'Hello', language: 'en')

        post :create, params: { status_id: hidden.id, source_language: 'en', target_language: 'ja' }
        expect(response).to have_http_status(404)

        post :create, params: { status_id: owned.id, source_language: 'en', target_language: 'ja' }
        expect(response).to have_http_status(403)
        expect(body_as_json[:error]).to eq 'This action is not allowed'
        expect(backend).not_to have_received(:translate)
      end
    end

    it 'rejects an application-only token' do
      app_token = Fabricate(:accessible_access_token, resource_owner_id: nil, scopes: 'read:statuses')
      allow(controller).to receive(:doorkeeper_token).and_return(app_token)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(422)
    end
  end
end
