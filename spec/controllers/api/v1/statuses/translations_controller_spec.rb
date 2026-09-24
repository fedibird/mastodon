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

    it 'rejects an application-only token' do
      app_token = Fabricate(:accessible_access_token, resource_owner_id: nil, scopes: 'read:statuses')
      allow(controller).to receive(:doorkeeper_token).and_return(app_token)

      post :create, params: { status_id: status.id }

      expect(response).to have_http_status(422)
    end
  end
end
