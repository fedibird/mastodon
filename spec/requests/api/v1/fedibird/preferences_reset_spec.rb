# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/fedibird/preferences/reset' do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true)) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences') }
  let(:headers) do
    {
      'Authorization' => "Bearer #{token.token}",
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
    }
  end

  after { discard_user(user) }

  def discard_user(record)
    return unless record&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: record.id).delete_all
    Doorkeeper::AccessToken.where(resource_owner_id: record.id).delete_all
    User.where(id: record.id).delete_all
    Account.where(id: record.account_id).delete_all
  end

  def post_raw(body, extra_headers: headers)
    post '/api/v1/fedibird/preferences/reset', params: body, headers: extra_headers
  end

  def post_reset(keys, scopes: 'write:preferences', owner: user)
    access = Fabricate(:accessible_access_token, resource_owner_id: owner&.id, scopes: scopes)
    post_raw(
      { reset: keys }.to_json,
      extra_headers: headers.merge('Authorization' => "Bearer #{access.token}")
    )
  end

  def store(record, key, value)
    row = Setting.unscoped.find_or_initialize_by(thing_type: 'User', thing_id: record.id, var: key)
    row.value = value
    row.save!
    row
  end

  def row(record, key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: record.id, var: key)
  end

  it 'routes POST only' do
    expect(Rails.application.routes.recognize_path('/api/v1/fedibird/preferences/reset', method: :post)).to include(
      controller: 'api/v1/fedibird/preferences',
      action: 'reset'
    )
    %i(get patch put delete).each do |method|
      recognized = Rails.application.routes.recognize_path('/api/v1/fedibird/preferences/reset', method: method)
      expect(recognized[:action]).not_to eq('reset'), method.to_s
    end
  end

  it 'allows only write:preferences' do
    store(user, 'default_sensitive', true)
    %w(write write:accounts read read:preferences read:accounts profile).each do |scope|
      post_reset(['user.default_sensitive'], scopes: scope)

      expect(response).to have_http_status(403), scope
      expect(row(user, 'default_sensitive').value).to be true
    end

    post_reset(['user.default_sensitive'])

    expect(response).to have_http_status(200)
    expect(response.headers['Cache-Control']).to eq 'private, no-store'
    expect(row(user, 'default_sensitive')).to be_nil
  end

  it 'rejects a missing token and client credentials' do
    store(user, 'default_sensitive', true)
    post '/api/v1/fedibird/preferences/reset', params: '{"reset":["user.default_sensitive"]}', headers: headers.except('Authorization')
    expect(response).to have_http_status(401)
    expect(row(user, 'default_sensitive').value).to be true

    post_reset(['user.default_sensitive'], owner: nil)
    expect(response).to have_http_status(422)
    expect(row(user, 'default_sensitive').value).to be true
  end

  it 'deletes present and nil rows, and does nothing when the row is already absent' do
    store(user, 'default_sensitive', true)
    nil_row = Setting.unscoped.new(thing_type: 'User', thing_id: user.id, var: 'reduce_motion')
    nil_row.value = nil
    nil_row.save!

    post_reset(%w(user.default_sensitive user.reduce_motion))

    expect(response).to have_http_status(200)
    sensitive = body_as_json[:preferences][:'user.default_sensitive']
    motion = body_as_json[:preferences][:'user.reduce_motion']
    expect(sensitive).to include(state: 'absent', configured: nil, effective: false)
    expect(motion).to include(state: 'absent', configured: nil, effective: false)
    expect(row(user, 'default_sensitive')).to be_nil
    expect(row(user, 'reduce_motion')).to be_nil

    expect(Rails.cache).not_to receive(:delete)
    post_reset(['user.default_sensitive'])
    expect(response).to have_http_status(200)
    expect(body_as_json[:preferences][:'user.default_sensitive'][:state]).to eq 'absent'
  end

  it 'accepts an empty reset list and collapses duplicate keys' do
    store(user, 'default_privacy', 'public')
    post_raw('{"reset":[]}')
    expect(response).to have_http_status(200)
    expect(row(user, 'default_privacy').value).to eq 'public'

    expect_any_instance_of(UserPreferences::Writer).to receive(:apply).and_wrap_original do |method, **kwargs|
      expect(kwargs[:resets]).to eq ['default_privacy']
      method.call(**kwargs)
    end
    post_raw('{"reset":["user.default_privacy","user.default_privacy"]}')

    expect(response).to have_http_status(200)
    expect(row(user, 'default_privacy')).to be_nil
  end

  it 'rolls back every reset when a later delete fails' do
    store(user, 'default_privacy', 'public')
    store(user, 'default_language', 'de')
    allow_any_instance_of(UserPreferences::Writer).to receive(:delete_row).and_wrap_original do |method, user_id, key|
      raise 'second reset failed' if key == 'default_language'

      method.call(user_id, key)
    end

    expect do
      post_reset(%w(user.default_privacy user.default_language))
    end.to raise_error(RuntimeError, 'second reset failed')

    expect(row(user, 'default_privacy').value).to eq 'public'
    expect(row(user, 'default_language').value).to eq 'de'
  end

  it 'does not delete another user or a valid row mixed with an unknown key' do
    other = Fabricate(:user, locale: 'de')
    store(user, 'default_privacy', 'public')
    store(user, 'default_language', 'de')
    store(other, 'default_language', 'de')

    post_reset(['user.default_privacy', 'user.theme'])

    expect(response).to have_http_status(422)
    expect(row(user, 'default_privacy').value).to eq 'public'
    expect(row(user, 'default_language').value).to eq 'de'
    expect(row(other, 'default_language').value).to eq 'de'
  ensure
    discard_user(other)
  end

  it 'restores locked and unlocked privacy defaults without writing a new row' do
    store(user, 'default_privacy', 'public')
    post_reset(['user.default_privacy'])
    other = ActiveRecord::Base.connection_pool.checkout
    begin
      count = other.select_value(<<~SQL.squish)
        SELECT COUNT(*) FROM settings
        WHERE thing_type = 'User' AND thing_id = #{user.id.to_i} AND var = 'default_privacy'
      SQL
      expect(count.to_i).to eq 0
    ensure
      ActiveRecord::Base.connection_pool.checkin(other)
    end
    privacy = body_as_json[:preferences][:'user.default_privacy']
    expect(privacy).to include(state: 'absent', configured: nil, effective: 'private')

    user.account.update!(locked: false)
    store(user, 'default_privacy', 'private')
    post_reset(['user.default_privacy'])
    expect(row(user, 'default_privacy')).to be_nil
    expect(body_as_json[:preferences][:'user.default_privacy']).to include(state: 'absent', effective: 'public')
  end

  it 'recalculates the derived language and leaves the translation bar row alone' do
    store(user, 'default_language', 'de')
    store(user, 'new_features_policy', 'tester')
    store(user, 'show_translation_bar', 'nope')

    post_reset(['user.default_language'])

    language = body_as_json[:preferences][:'user.default_language']
    preferred = body_as_json[:preferences][:'user.preferred_posting_language']
    expect(language).to include(state: 'absent', configured: nil)
    expect(preferred[:state]).to eq 'derived'
    expect(preferred[:effective]).to eq 'ja'
    expect(row(user, 'preferred_posting_language')).to be_nil
    expect(row(user, 'default_language')).to be_nil

    post_reset(['user.new_features_policy'])

    expect(row(user, 'new_features_policy')).to be_nil
    expect(row(user, 'show_translation_bar').value).to eq 'nope'
    expect(body_as_json[:preferences][:'user.new_features_policy'][:effective]).to eq 'default'
    expect(body_as_json[:preferences][:'user.show_translation_bar']).to include(configured: 'nope', effective: 'target')
  end

  it 'removes stored font values and does not treat a saved default as a reset' do
    store(user, 'content_font_size', 18)
    store(user, 'info_font_size', '18')
    post_reset(%w(user.content_font_size user.info_font_size))
    expect(row(user, 'content_font_size')).to be_nil
    expect(row(user, 'info_font_size')).to be_nil
    expect(body_as_json[:preferences][:'user.content_font_size']).to include(state: 'absent', effective: 15)

    store(user, 'content_font_size', 'invalid')
    post_reset(['user.content_font_size'])
    expect(row(user, 'content_font_size')).to be_nil
    expect(body_as_json[:preferences][:'user.content_font_size'][:effective]).to eq 15

    patch '/api/v1/fedibird/preferences', params: '{"preferences":{"user.default_sensitive":false}}', headers: headers
    expect(response).to have_http_status(200)
    expect(row(user, 'default_sensitive').value).to be false
    post_reset(['user.default_sensitive'])
    expect(row(user, 'default_sensitive')).to be_nil
    expect(body_as_json[:preferences][:'user.default_sensitive']).to include(state: 'absent', effective: false)
  end

  it 'returns 200 when cache deletion fails after the row is committed away' do
    store(user, 'default_sensitive', true)
    allow(Rails.cache).to receive(:delete).and_raise(StandardError, 'cache unavailable')

    post_reset(['user.default_sensitive'])

    expect(response).to have_http_status(200)
    expect(row(user, 'default_sensitive')).to be_nil
    expect(body_as_json[:preferences][:'user.default_sensitive'][:state]).to eq 'absent'
  end

  it 'rejects invalid reset documents without deleting valid rows' do
    store(user, 'default_privacy', 'public')
    payloads = [
      {},
      { reset: nil },
      { reset: 'user.default_privacy' },
      { reset: { 'user.default_privacy' => true } },
      { reset: ['user.default_privacy', 1] },
      { reset: [true] },
      { reset: [nil] },
      { reset: ['user.preferred_posting_language'] },
      { reset: ['user.noindex'] },
      { reset: ['user.default_privacy'], preferences: {} },
      { reset: ['user.default_privacy'], extra: true },
    ]
    payloads.each do |payload|
      post_raw(payload.to_json)

      expect(response).to have_http_status(422), payload.inspect
      expect(row(user, 'default_privacy').value).to eq 'public'
    end
  end

  it 'rejects bad JSON, then accepts a later reset' do
    store(user, 'default_sensitive', true)
    ['{', '{ "reset": }', '', '[]', '"reset"', 'null'].each do |body|
      post_raw(body)

      expect(response).to have_http_status(422), body.inspect
      expect(row(user, 'default_sensitive').value).to be true
    end
    post_raw('{')
    expect(body_as_json).to eq(error: 'Invalid preferences', errors: [{ key: nil, code: 'invalid_body' }])

    post_raw('{"reset":["user.default_sensitive"]}')

    expect(response).to have_http_status(200)
    expect(row(user, 'default_sensitive')).to be_nil
  end

  it 'rejects a non-JSON content type and a PATCH null' do
    store(user, 'default_sensitive', true)
    post '/api/v1/fedibird/preferences/reset',
         params: { reset: ['user.default_sensitive'] },
         headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/x-www-form-urlencoded' }

    expect(response).to have_http_status(422)
    expect(row(user, 'default_sensitive').value).to be true

    patch '/api/v1/fedibird/preferences',
          params: '{"preferences":{"user.default_sensitive":null}}',
          headers: headers

    expect(response).to have_http_status(422)
    expect(row(user, 'default_sensitive').value).to be true
  end
end
