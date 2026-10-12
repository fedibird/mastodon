# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::PreferencesController, type: :controller do
  render_views

  def authorize(owner, scopes)
    token = Fabricate(:accessible_access_token, resource_owner_id: owner&.id, scopes: scopes)
    allow(controller).to receive(:doorkeeper_token) { token }
    token
  end

  def store_setting(user, var, value)
    record = Setting.unscoped.find_or_initialize_by(thing_type: 'User', thing_id: user.id, var: var)
    record.value = value
    record.save!
    record
  end

  def setting_queries
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      queries << sql if sql.include?('FROM "settings"') && !sql.include?('SCHEMA')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  describe 'GET #show' do
    let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true)) }

    it 'returns the signed-in user preferences for read:preferences' do
      authorize(user, 'read:preferences')
      get :show

      expect(response).to have_http_status(200)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      body = body_as_json
      expect(body[:version]).to eq 1
      expect(body[:preferences].keys).to contain_exactly(
        :'user.default_privacy',
        :'user.default_sensitive',
        :'user.default_language',
        :'user.preferred_posting_language',
        :'user.show_translation_bar',
        :'user.translation_preferred_mode',
        :'user.new_features_policy',
        :'user.content_font_size',
        :'user.info_font_size',
        :'user.reduce_motion'
      )
      privacy = body[:preferences][:'user.default_privacy']
      expect(privacy[:state]).to eq 'absent'
      expect(privacy[:configured]).to be_nil
      expect(privacy[:effective]).to eq 'private'
      expect(privacy[:public_value]).to eq 'private'
      expect(privacy[:public_valid]).to be true
      expect(privacy[:validation_errors]).to eq []
    end

    it 'accepts the read scope' do
      authorize(user, 'read')
      get :show

      expect(response).to have_http_status(200)
    end

    it 'rejects read:accounts alone' do
      authorize(user, 'read:accounts')
      get :show

      expect(response).to have_http_status(403)
    end

    it 'rejects a missing token' do
      allow(controller).to receive(:doorkeeper_token) { nil }
      get :show

      expect(response).to have_http_status(401)
    end

    it 'rejects a client-credentials token' do
      authorize(nil, 'read:preferences')
      get :show

      expect(response).to have_http_status(422)
      expect(response.body).not_to include('default_privacy')
    end

    it 'does not return another user preferences' do
      other = Fabricate(:user, locale: 'de', account: Fabricate(:account, locked: false))
      store_setting(other, 'default_language', 'de')
      store_setting(user, 'default_language', 'ja-JP')
      authorize(user, 'read:preferences')
      get :show

      language = body_as_json[:preferences][:'user.default_language']
      preferred = body_as_json[:preferences][:'user.preferred_posting_language']
      expect(language[:configured]).to eq 'ja-JP'
      expect(language[:effective]).to eq 'ja-JP'
      expect(preferred[:state]).to eq 'derived'
      expect(preferred[:effective]).to eq 'ja'
      expect(response.body).not_to include('"de"')
    end

    it 'keeps false, an empty string, and a stored nil distinct' do
      store_setting(user, 'default_sensitive', false)
      store_setting(user, 'default_privacy', '')
      store_setting(user, 'reduce_motion', nil)
      authorize(user, 'read:preferences')
      get :show

      prefs = body_as_json[:preferences]
      expect(prefs[:'user.default_sensitive']).to include(state: 'present', configured: false, effective: false, public_value: false, public_valid: true)
      expect(prefs[:'user.default_privacy']).to include(state: 'present', configured: '', effective: '', public_value: '', public_valid: true)
      motion = prefs[:'user.reduce_motion']
      expect(motion[:state]).to eq 'nil'
      expect(motion[:configured]).to be_nil
      expect(motion[:effective]).to be_nil
      expect(motion[:public_value]).to be_nil
      expect(motion[:public_valid]).to be false
      expect(motion[:validation_errors]).to include(field: 'public_value', expected: ['boolean'], actual: 'nil')
    end

    it 'keeps a stored direct visibility' do
      store_setting(user, 'default_privacy', 'direct')
      authorize(user, 'read:preferences')
      get :show

      privacy = body_as_json[:preferences][:'user.default_privacy']
      expect(privacy[:configured]).to eq 'direct'
      expect(privacy[:effective]).to eq 'direct'
      expect(privacy[:public_value]).to eq 'direct'
      expect(privacy[:public_valid]).to be true
    end

    it 'normalizes a numeric font string and reports an invalid one without repair' do
      store_setting(user, 'content_font_size', '18')
      store_setting(user, 'info_font_size', 'invalid')
      authorize(user, 'read:preferences')
      get :show

      content = body_as_json[:preferences][:'user.content_font_size']
      info = body_as_json[:preferences][:'user.info_font_size']
      expect(content[:configured]).to eq '18'
      expect(content[:effective]).to eq '18'
      expect(content[:public_value]).to eq 18
      expect(content[:public_valid]).to be true
      expect(info[:configured]).to eq 'invalid'
      expect(info[:effective]).to eq 'invalid'
      expect(info[:public_value]).to be_nil
      expect(info[:public_valid]).to be false
      expect(info[:validation_errors]).to include(field: 'public_value', expected: ['integer'], actual: 'string')
      expect(Setting.unscoped.find_by(thing_id: user.id, var: 'info_font_size').value).to eq 'invalid'
    end

    it 'keeps a legacy translation boolean and does not add original as a mode' do
      store_setting(user, 'new_features_policy', 'conservative')
      store_setting(user, 'show_translation_bar', true)
      store_setting(user, 'translation_preferred_mode', 'original')
      authorize(user, 'read:preferences')
      get :show

      bar = body_as_json[:preferences][:'user.show_translation_bar']
      mode = body_as_json[:preferences][:'user.translation_preferred_mode']
      expect(bar[:configured]).to be true
      expect(bar[:effective]).to eq 'always'
      expect(bar[:public_value]).to eq 'always'
      expect(mode[:configured]).to eq 'original'
      expect(mode[:effective]).to eq 'translated'
      expect(mode[:public_value]).to eq 'translated'
    end

    it 'loads settings once and does not write cache' do
      authorize(user, 'read:preferences')
      expect(Rails.cache).not_to receive(:write)
      expect(Rails.cache).not_to receive(:fetch)
      queries = setting_queries { get :show }

      expect(response).to have_http_status(200)
      selects = queries.grep(/\ASELECT/i)
      expect(selects).to contain_exactly(a_string_including('FROM "settings"'))
    end
  end

  describe 'routes' do
    it 'does not expose a write route' do
      %i(patch put post).each do |method|
        recognized = Rails.application.routes.recognize_path('/api/v1/fedibird/preferences', method: method)
        expect(recognized[:controller]).not_to eq 'api/v1/fedibird/preferences'
        expect(recognized[:action]).not_to eq 'update'
      end
      expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences', method: :get)).to include(controller: 'api/v1/fedibird/preferences', action: 'show')
      expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences/schema', method: :get)).to include(controller: 'api/v1/fedibird/preferences/schema', action: 'show')
    end
  end
end
