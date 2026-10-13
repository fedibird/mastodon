# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'preference writes when the change notification cannot be published' do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user, email: 'pref-http-secret@example.test', locale: 'ja', account: Fabricate(:account, username: 'preftokenuser', locked: false)) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences') }
  let(:headers) do
    {
      'Authorization' => "Bearer #{token.token}",
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
    }
  end

  before do
    @messages = []
    @errors = []
    allow(RedisConfiguration).to receive(:with).and_wrap_original do |method, &block|
      method.call do |redis|
        block.call(RaisingPublisher.new(redis, @messages))
      end
    end
    allow(Rails.logger).to receive(:error).and_wrap_original do |method, *args|
      @errors << args.first
      method.call(*args)
    end
  end

  after { discard_user(user) }

  def discard_user(record)
    return unless record&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: record.id).delete_all
    UserPreferenceRevision.where(user_id: record.id).delete_all
    Doorkeeper::AccessToken.where(resource_owner_id: record.id).delete_all
    Account.where(id: record.account_id).delete_all
    User.where(id: record.id).delete_all
  end

  def row(key)
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: key)
  end

  it 'returns the usual preference document when PATCH cannot publish' do
    patch '/api/v1/fedibird/preferences',
          params: '{"preferences":{"user.default_language":"zh-TW"}}',
          headers: headers

    expect(response).to have_http_status(200)
    expect(JSON.parse(response.body).keys).to match_array(%w(version preferences))
    expect(body_as_json[:version]).to eq 1
    expect(body_as_json[:preferences][:'user.default_language']).to include(state: 'present', configured: 'zh-TW')
    expect(response.body).not_to include('preferences_changed')
    expect(row('default_language').value).to eq 'zh-TW'
    expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 1
    expect(@messages.size).to eq 1
    expect(@messages.first.first).to eq "timeline:preferences:#{user.account_id}"
    raw = @messages.first.last
    expect(raw).not_to include(token.token)
    expect(raw).not_to include(user.email)
    expect(raw).not_to include('preftokenuser')
    expect(raw).not_to include('zh-TW')
    expect(@errors.join).to include('error=Redis::CannotConnectError')
    expect(@errors.join).not_to include(token.token)
  end

  it 'returns the usual preference document when reset cannot publish' do
    UserPreferences::Writer.new(user).apply(updates: { 'default_sensitive' => true })
    @messages.clear
    @errors.clear

    post '/api/v1/fedibird/preferences/reset',
         params: '{"reset":["user.default_sensitive"]}',
         headers: headers

    expect(response).to have_http_status(200)
    expect(JSON.parse(response.body).keys).to match_array(%w(version preferences))
    expect(body_as_json[:version]).to eq 1
    expect(body_as_json[:preferences][:'user.default_sensitive']).to include(state: 'absent', configured: nil)
    expect(response.body).not_to include('preferences_changed')
    expect(row('default_sensitive')).to be_nil
    expect(UserPreferenceRevision.find_by!(user_id: user.id).revision).to eq 2
    expect(@messages.size).to eq 1
    expect(JSON.parse(@messages.first.last).dig('payload', 'changed_keys')).to eq ['user.default_sensitive']
    expect(@messages.first.last).not_to include(token.token)
    expect(@messages.first.last).not_to include('true')
    expect(@errors.join).to include('error=Redis::CannotConnectError')
  end
end
