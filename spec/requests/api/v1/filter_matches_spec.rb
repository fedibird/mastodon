# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/fedibird/filters/matches' do
  let(:user) { Fabricate(:user) }
  let(:scopes) { 'read:statuses read:filters' }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:path) { '/api/v1/fedibird/filters/matches' }

  def request_matches(ids, **options)
    post path, params: { status_ids: ids }, headers: headers, as: :json, **options
  end

  def json
    JSON.parse(response.body)
  end

  it 'accepts zero IDs and returns the explicit empty contract with private no-store caching' do
    request_matches([])
    expect(response).to have_http_status(200)
    expect(json).to eq('matches' => {}, 'unavailable' => [])
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
  end

  it 'normalizes duplicates, preserves order, and distinguishes empty matches from unavailable' do
    status = Fabricate(:status)
    missing = '9223372036854775807'
    request_matches([missing, status.id.to_s, missing, status.id.to_s])
    expect(response).to have_http_status(200)
    expect(json).to eq('matches' => { status.id.to_s => [] }, 'unavailable' => [missing])
  end

  it 'accepts 100 distinct IDs' do
    ids = Fabricate.times(100, :status).map { |status| status.id.to_s }
    request_matches(ids)
    expect(response).to have_http_status(200)
    expect(json['matches'].keys).to eq(ids)
    expect(json['unavailable']).to eq([])
  end

  [nil, {}, '', ['0'], ['01'], ['-1'], ['+1'], ['1.0'], ['1e2'], [' 1'], ["1\n"], ['１２'], [1], [1.5], [true], [nil], [[]], [{}], ['9223372036854775808'], ['9' * 100], Array.new(101, '1')].each do |invalid|
    it "rejects invalid input #{invalid.inspect.truncate(80)} as a whole" do
      request_matches(invalid)
      expect(response).to have_http_status(422)
      expect(json).to have_key('error')
      expect(json).not_to have_key('matches')
    end
  end

  it 'rejects a missing field' do
    post path, params: {}, headers: headers, as: :json
    expect(response).to have_http_status(422)
  end

  it 'rejects a valid ID mixed with null rather than returning partial success' do
    status = Fabricate(:status)
    request_matches([status.id.to_s, nil])
    expect(response).to have_http_status(422)
    expect(json).not_to have_key('matches')
  end

  it 'requires a JSON object and rejects form input' do
    post path, params: { status_ids: [] }, headers: headers
    expect(response).to have_http_status(415)
    post path, params: '["123"]', headers: headers.merge('CONTENT_TYPE' => 'application/json')
    expect(response).to have_http_status(422)
  end

  it 'rejects a large body before JSON parsing' do
    post path, params: '{' + ('x' * 8192), headers: headers.merge('CONTENT_TYPE' => 'application/json')
    expect(response).to have_http_status(413)
    expect(json).to have_key('error')
  end

  it 'enforces the body limit for Rails format and trailing-slash routes' do
    ["#{path}.json", "#{path}/"].each do |url|
      post url, params: '{' + ('x' * 8192), headers: headers.merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(413)
    end
  end

  it 'rejects oversized results rather than truncating matches' do
    service = instance_double(FilterMatchesService, call: { matches: { '1' => ['1' * 1_048_576] }, unavailable: [] })
    allow(FilterMatchesService).to receive(:new).and_return(service)
    request_matches(['1'])
    expect(response).to have_http_status(422)
    expect(json).to have_key('error')
    expect(json).not_to have_key('matches')
  end

  it 'uses the existing malformed JSON error' do
    post path, params: '{', headers: headers.merge('CONTENT_TYPE' => 'application/json')
    expect(response).to have_http_status(400)
  end

  context 'without a token' do
    let(:headers) { {} }

    it 'requires authentication' do
      request_matches([])
      expect(response).to have_http_status(401)
    end
  end

  ['read:statuses', 'read:filters', 'write', 'write:filters', ''].each do |scope|
    context "with only #{scope.inspect}" do
      let(:scopes) { scope }

      it 'rejects insufficient scopes' do
        request_matches([])
        expect(response).to have_http_status(403)
      end
    end
  end

  context 'with umbrella read permission' do
    let(:scopes) { 'read' }

    it 'accepts the existing umbrella scope' do
      request_matches([])
      expect(response).to have_http_status(200)
    end
  end

  it 'rejects revoked tokens' do
    token.revoke
    request_matches([])
    expect(response).to have_http_status(401)
  end

  it 'rejects expired tokens' do
    token.update!(created_at: 2.hours.ago, expires_in: 60)
    request_matches([])
    expect(response).to have_http_status(401)
  end

  it 'cannot return another viewer’s filters or status text' do
    status = Fabricate(:status, text: 'secret keyword')
    other = Fabricate(:custom_filter)
    Fabricate(:custom_filter_keyword, custom_filter: other, keyword: 'secret')
    own = Fabricate(:custom_filter, account: user.account)
    Fabricate(:custom_filter_keyword, custom_filter: own, keyword: 'secret')
    request_matches([status.id.to_s])
    expect(json).to eq('matches' => { status.id.to_s => [own.id.to_s] }, 'unavailable' => [])
    expect(response.body).not_to include('secret', 'keyword_matches', 'status_matches', 'content')
  end
end
