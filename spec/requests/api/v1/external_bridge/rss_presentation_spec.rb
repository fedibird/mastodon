# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe 'RSS subscription presentation API' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'presentationowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:bundle) { project_for(owner, body: 'Owner only article') }
  let(:owner_headers) { auth_headers_for(owner) }

  before do
    enable_external_bridge_rss!(owner)
    bundle
  end

  describe 'GET /api/v1/external_bridge/rss/subscriptions' do
    it 'adds the display choices without removing the existing fields' do
      get '/api/v1/external_bridge/rss/subscriptions', headers: owner_headers

      row = body_as_json.first
      expect(row[:id]).to eq(bundle[:subscription].id.to_s)
      expect(row[:state]).to eq('active')
      expect(row[:source][:url]).to eq(bundle[:source].canonical_key)
      expect(row[:presentation]).to eq(
        media_sensitive: false,
        cw_enabled: false,
        language_mode: 'unspecified',
        language: nil,
        revision: '0',
        applied_revision: '0',
        state: 'settled'
      )
    end
  end

  describe 'PATCH /api/v1/external_bridge/rss/subscriptions/:id' do
    let(:path) { "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}" }

    it 'stores the choices and reports that imported posts are still updating' do
      allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

      patch path, params: { media_sensitive: true, cw_enabled: false, state: 'paused', user_id: stranger.id }, headers: owner_headers, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:presentation]).to include(media_sensitive: true, cw_enabled: false, revision: '1', state: 'applying')
      subscription = bundle[:subscription].reload
      expect(subscription.state).to eq('active')
      expect(subscription.user_id).to eq(owner.id)
      expect(subscription.media_sensitive).to eq(true)
      expect(bundle[:status].reload.sensitive).to eq(false)
      expect(ExternalBridge::RSS::PresentationReconcileWorker).to have_received(:perform_async).with(subscription.id, 1, 0, kind_of(String))
    end

    it 'updates one flag and leaves the other' do
      bundle[:subscription].update_columns(cw_enabled: true, presentation_revision: 4, presentation_applied_revision: 4)
      allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

      patch path, params: { media_sensitive: true }, headers: owner_headers, as: :json

      expect(response).to have_http_status(200)
      subscription = bundle[:subscription].reload
      expect(subscription.media_sensitive).to eq(true)
      expect(subscription.cw_enabled).to eq(true)
      expect(subscription.presentation_revision).to eq(5)
    end

    it 'rejects a missing or malformed flag, another user on the same account, a reader token, and a deleting feed' do
      patch path, params: {}, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)
      expect(body_as_json[:error]).to eq('invalid_presentation')

      patch path, params: { media_sensitive: 'yes', cw_enabled: false }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)
      expect(bundle[:subscription].reload.presentation_revision).to eq(0)

      patch path, params: { media_sensitive: true, cw_enabled: true }, headers: auth_headers_for(roommate), as: :json
      expect(response).to have_http_status(404)

      patch path, params: { media_sensitive: true, cw_enabled: true }, headers: auth_headers_for(stranger), as: :json
      expect(response).to have_http_status(404)

      patch path, params: { media_sensitive: true, cw_enabled: true }, headers: auth_headers_for(owner, 'read:statuses'), as: :json
      expect(response).to have_http_status(403)

      bundle[:subscription].update!(state: 'deleting')
      patch path, params: { media_sensitive: true, cw_enabled: true }, headers: owner_headers, as: :json
      expect(response).to have_http_status(409)
      expect(bundle[:subscription].reload.media_sensitive).to eq(false)
    end

    it 'switches fixed, automatic, and unspecified language without treating an omitted key as unspecified' do
      allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

      patch path, params: { language_mode: 'fixed', language: 'ja' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:presentation]).to include(language_mode: 'fixed', language: 'ja', revision: '1', state: 'applying')

      patch path, params: { media_sensitive: true }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      subscription = bundle[:subscription].reload
      expect(subscription.language_mode).to eq('fixed')
      expect(subscription.language).to eq('ja')
      expect(subscription.media_sensitive).to eq(true)

      patch path, params: { language_mode: 'auto', language: nil }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      expect(bundle[:subscription].reload.language_mode).to eq('auto')
      expect(bundle[:subscription].language).to be_nil

      patch path, params: { language_mode: 'unspecified' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      expect(bundle[:subscription].reload.language_mode).to eq('unspecified')
      expect(bundle[:subscription].language).to be_nil
      expect(bundle[:source].reload.attributes).not_to have_key('language_mode')
      expect(bundle[:resource].reload.attributes).not_to have_key('language_mode')
    end

    it 'rejects an unknown mode, an unknown code, a code with the wrong mode, and a bare code' do
      patch path, params: { language_mode: 'detect' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)
      expect(body_as_json[:error]).to eq('invalid_presentation')

      patch path, params: { language_mode: 'fixed', language: 'zz' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)

      patch path, params: { language_mode: 'fixed', language: 'EN' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)

      patch path, params: { language_mode: 'auto', language: 'en' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)

      patch path, params: { language_mode: 'unspecified', language: 'ja' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)

      patch path, params: { language: 'ja' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(422)

      patch path, params: { language_mode: 'fixed', language: 'ja' }, headers: auth_headers_for(roommate), as: :json
      expect(response).to have_http_status(404)

      expect(bundle[:subscription].reload.language_mode).to eq('unspecified')
      expect(bundle[:subscription].language).to be_nil
      expect(bundle[:subscription].presentation_revision).to eq(0)
    end

    it 'accepts regional and three-letter codes Fedibird already supports' do
      allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

      %w(zh-CN zh-TW ast).each do |code|
        patch path, params: { language_mode: 'fixed', language: code }, headers: owner_headers, as: :json

        expect(response).to have_http_status(200)
        expect(bundle[:subscription].reload.language).to eq(code)
        expect(bundle[:subscription].language_mode).to eq('fixed')
      end

      patch path, params: { language_mode: 'auto' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      expect(bundle[:subscription].reload.language_mode).to eq('auto')
      expect(bundle[:subscription].language).to be_nil

      patch path, params: { language_mode: 'unspecified' }, headers: owner_headers, as: :json
      expect(response).to have_http_status(200)
      expect(bundle[:subscription].reload.language_mode).to eq('unspecified')
    end

    it 'still saves when RSS import is turned off' do
      Setting.external_bridge_rss = false
      allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

      patch path, params: { cw_enabled: true }, headers: owner_headers, as: :json

      expect(response).to have_http_status(200)
      expect(bundle[:subscription].reload.cw_enabled).to eq(true)
    end
  end
end

# rubocop:enable Metrics/BlockLength
