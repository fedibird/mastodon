# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/v1/fedibird/preferences JSON body' do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: false)) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:preferences') }
  let(:headers) do
    {
      'Authorization' => "Bearer #{token.token}",
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
    }
  end

  after do
    next unless user&.id

    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    Doorkeeper::AccessToken.where(resource_owner_id: user.id).delete_all
    User.where(id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
  end

  def patch_raw(body)
    patch '/api/v1/fedibird/preferences', params: body, headers: headers
  end

  def settings_count
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).count
  end

  it 'rejects incomplete JSON and a body with an illegal token' do
    ['{', '{ "preferences": }'].each do |body|
      patch_raw(body)

      expect(response).to have_http_status(422), body
      expect(body_as_json).to eq(
        error: 'Invalid preferences',
        errors: [{ key: nil, code: 'invalid_body' }]
      )
      expect(settings_count).to eq 0
    end
  end

  it 'rejects an empty body and JSON values that are not objects' do
    ['', '[]', '"hello"', 'null'].each do |body|
      patch_raw(body)

      expect(response).to have_http_status(422), body.inspect
      expect(body_as_json[:error]).to eq 'Invalid preferences'
      expect(settings_count).to eq 0
    end
  end

  it 'accepts an empty preferences object and still saves a later valid patch' do
    patch_raw('{')
    expect(response).to have_http_status(422)
    expect(settings_count).to eq 0

    patch_raw('{"preferences":{}}')

    expect(response).to have_http_status(200)
    expect(body_as_json[:version]).to eq 1
    expect(body_as_json[:preferences].keys).to include(:'user.default_sensitive')
    expect(settings_count).to eq 0

    patch_raw('{"preferences":{"user.default_sensitive":false}}')

    expect(response).to have_http_status(200)
    expect(body_as_json[:preferences][:'user.default_sensitive']).to include(state: 'present', configured: false)
    expect(Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'default_sensitive').value).to be false
  end
end
