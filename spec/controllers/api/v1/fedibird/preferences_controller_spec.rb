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

    it 'rejects write:preferences alone' do
      authorize(user, 'write:preferences')
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
    it 'routes GET and PATCH and does not route PUT or POST to this controller' do
      expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences', method: :get)).to include(controller: 'api/v1/fedibird/preferences', action: 'show')
      expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences', method: :patch)).to include(controller: 'api/v1/fedibird/preferences', action: 'update')
      %i(put post delete).each do |method|
        recognized = Rails.application.routes.recognize_path('/api/v1/fedibird/preferences', method: method)
        expect(recognized[:controller]).not_to eq 'api/v1/fedibird/preferences'
        expect(recognized[:action]).not_to eq 'update'
      end
      expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences/schema', method: :get)).to include(controller: 'api/v1/fedibird/preferences/schema', action: 'show')
    end
  end

  describe 'PATCH #update' do
    self.use_transactional_tests = false

    let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true)) }

    after { discard_user(user) }

    def patch_json(payload = nil, scopes: 'write:preferences', owner: user, preferences: :missing)
      body = preferences == :missing ? payload : { preferences: preferences }
      authorize(owner, scopes)
      patch :update, body: body.to_json, as: :json
    end

    def stored(record, key)
      Setting.unscoped.find_by(thing_type: 'User', thing_id: record.id, var: key)
    end

    def discard_user(record)
      return unless record&.id

      Setting.unscoped.where(thing_type: 'User', thing_id: record.id).delete_all
      Doorkeeper::AccessToken.where(resource_owner_id: record.id).delete_all
      User.where(id: record.id).delete_all
      Account.where(id: record.account_id).delete_all
    end

    it 'saves the nine keys and returns the same document as GET' do
      patch_json(preferences: {
        'user.default_privacy' => 'private',
        'user.default_sensitive' => false,
        'user.default_language' => 'ja',
        'user.show_translation_bar' => 'target',
        'user.translation_preferred_mode' => 'bilingual',
        'user.new_features_policy' => 'default',
        'user.content_font_size' => 18,
        'user.info_font_size' => 12,
        'user.reduce_motion' => true,
      })

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
      sensitive = body[:preferences][:'user.default_sensitive']
      expect(sensitive).to include(state: 'present', configured: false, effective: false, public_value: false, public_valid: true)
      font = body[:preferences][:'user.content_font_size']
      expect(font[:configured]).to eq 18
      expect(font[:configured]).to be_a(Integer)
      expect(body[:preferences][:'user.preferred_posting_language'][:effective]).to eq 'ja'
      other = ActiveRecord::Base.connection_pool.checkout
      begin
        count = other.select_value(<<~SQL.squish)
          SELECT COUNT(*) FROM settings
          WHERE thing_type = 'User' AND thing_id = #{user.id.to_i} AND var = 'default_language'
        SQL
        expect(count.to_i).to eq 1
      ensure
        ActiveRecord::Base.connection_pool.checkin(other)
      end
    end

    it 'accepts the supported Chinese language tags without stripping them' do
      %w(zh-CN zh-TW zh-HK zh-YUE).each do |language|
        patch_json(preferences: { 'user.default_language' => language })

        expect(response).to have_http_status(200)
        expect(body_as_json[:preferences][:'user.default_language'][:configured]).to eq language
        expect(stored(user, 'default_language').value).to eq language
      end
    end

    it 'stores an explicit false and does not treat an empty object as a reset' do
      patch_json(preferences: { 'user.default_sensitive' => false })
      expect(body_as_json[:preferences][:'user.default_sensitive'][:state]).to eq 'present'

      patch_json(preferences: {})

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_sensitive').value).to be false
      expect(body_as_json[:preferences].keys.size).to eq 10
    end

    it 'updates policy and the translation bar together, and policy alone leaves the bar row' do
      patch_json(preferences: { 'user.new_features_policy' => 'conservative', 'user.show_translation_bar' => 'never' })
      expect(stored(user, 'show_translation_bar').value).to eq 'never'
      expect(stored(user, 'new_features_policy').value).to eq 'conservative'

      bar = stored(user, 'show_translation_bar')
      bar.update_columns(updated_at: 2.hours.ago)
      stamp = bar.reload.updated_at
      patch_json(preferences: { 'user.new_features_policy' => 'tester' })

      expect(stored(user, 'show_translation_bar').value).to eq 'never'
      expect(stored(user, 'show_translation_bar').reload.updated_at).to eq stamp
      expect(body_as_json[:preferences][:'user.show_translation_bar'][:effective]).to eq 'never'
    end

    it 'does not repair an unrelated invalid row and does not change another user' do
      other = Fabricate(:user, locale: 'de')
      store_setting(user, 'default_language', 'ja-JP')
      store_setting(other, 'default_language', 'de')
      user.settings['display_media'] = 'hide'

      patch_json(preferences: { 'user.reduce_motion' => true })

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_language').value).to eq 'ja-JP'
      expect(stored(other, 'default_language').value).to eq 'de'
      expect(user.settings['display_media']).to eq 'hide'
    ensure
      discard_user(other)
    end

    it 'keeps updated_at when the same value is sent again' do
      patch_json(preferences: { 'user.content_font_size' => 18 })
      record = stored(user, 'content_font_size')
      record.update_columns(updated_at: 2.hours.ago)
      stamp = record.reload.updated_at

      patch_json(preferences: { 'user.content_font_size' => 18 })

      expect(response).to have_http_status(200)
      expect(record.reload.updated_at).to eq stamp
    end

    it 'returns 200 when cache deletion fails after commit' do
      allow(Rails.cache).to receive(:delete).and_raise(StandardError, 'cache unavailable')

      patch_json(preferences: { 'user.default_sensitive' => false })

      expect(response).to have_http_status(200)
      expect(stored(user, 'default_sensitive').value).to be false
      expect(body_as_json[:preferences][:'user.default_sensitive'][:configured]).to be false
    end

    it 'rejects scopes other than write:preferences' do
      %w(write write:accounts read read:preferences read:accounts profile).each do |scope|
        authorize(user, scope)
        patch :update, params: { preferences: {} }, as: :json

        expect(response).to have_http_status(403), scope
      end
    end

    it 'rejects a missing token, a revoked token, and client credentials' do
      allow(controller).to receive(:doorkeeper_token) { nil }
      patch :update, params: { preferences: {} }, as: :json
      expect(response).to have_http_status(401)

      token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences')
      token.update!(revoked_at: Time.now.utc)
      allow(controller).to receive(:doorkeeper_token) { token }
      patch :update, params: { preferences: { 'user.default_sensitive' => false } }, as: :json
      expect(response).to have_http_status(401)
      expect(stored(user, 'default_sensitive')).to be_nil

      authorize(nil, 'write:preferences')
      patch :update, params: { preferences: { 'user.default_sensitive' => false } }, as: :json
      expect(response).to have_http_status(422)
      expect(stored(user, 'default_sensitive')).to be_nil
    end

    it 'can issue a write:preferences token' do
      token = Doorkeeper::AccessToken.new(
        application: Fabricate(:application),
        resource_owner_id: user.id,
        scopes: 'write:preferences',
        expires_in: Doorkeeper.configuration.access_token_expires_in
      )

      expect(token).to be_valid
      expect(token.save).to be true
    end

    it 'rejects malformed documents without writing' do
      store_setting(user, 'default_sensitive', true)

      [
        {},
        { preferences: nil },
        { preferences: ['user.default_sensitive'] },
        { preferences: {}, reset: ['user.default_language'] },
        { preferences: { 'user.default_sensitive' => nil } },
        { preferences: { 'user.default_sensitive' => 1 } },
        { preferences: { 'user.default_sensitive' => 'false' } },
        { preferences: { 'user.content_font_size' => '18' } },
        { preferences: { 'user.content_font_size' => 18.0 } },
        { preferences: { 'user.content_font_size' => 9 } },
        { preferences: { 'user.default_language' => 'ja-JP' } },
        { preferences: { 'user.default_privacy' => 'direct' } },
        { preferences: { 'user.default_privacy' => 'limited' } },
        { preferences: { 'user.translation_preferred_mode' => 'original' } },
        { preferences: { 'user.theme' => 'default' } },
        { preferences: { 'user.preferred_posting_language' => 'ja' } },
        { preferences: { 'user.default_sensitive' => false, 'user.default_language' => 'ja-JP' } },
      ].each do |payload|
        patch_json(payload)

        expect(response).to have_http_status(422), payload.inspect
        expect(response.body).not_to include('SELECT')
        expect(response.body).not_to include('settings')
        expect(stored(user, 'default_sensitive').value).to be true
      end
    end

    it 'rejects a non-JSON body before it can coerce values' do
      authorize(user, 'write:preferences')
      patch :update, params: { preferences: { 'user.content_font_size' => '18' } }

      expect(response).to have_http_status(422)
      expect(stored(user, 'content_font_size')).to be_nil
    end

    it 'returns the public key when a value is invalid' do
      patch_json(preferences: { 'user.default_language' => 'ja-JP' })

      expect(response).to have_http_status(422)
      expect(body_as_json[:error]).to eq 'Invalid preferences'
      expect(body_as_json[:errors]).to include(key: 'user.default_language', code: 'invalid_value')
    end

    it 'maps Conflict to 409 and does not turn unexpected errors into 422' do
      allow_any_instance_of(UserPreferences::Writer).to receive(:apply).and_raise(UserPreferences::Conflict)
      patch_json(preferences: { 'user.reduce_motion' => true })
      expect(response).to have_http_status(409)
      expect(body_as_json[:error]).to eq 'Preferences conflict'
      expect(response.body).not_to include('settings')

      allow_any_instance_of(UserPreferences::Writer).to receive(:apply).and_raise(RuntimeError, 'boom')
      expect { patch_json(preferences: { 'user.reduce_motion' => true }) }.to raise_error(RuntimeError, 'boom')
    end
  end
end
