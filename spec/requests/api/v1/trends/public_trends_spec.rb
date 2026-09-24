# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public trends API' do
  let(:account) { Fabricate(:account, discoverable: true, trendable: true) }

  before do
    Setting.trends = true
    Rails.cache.clear
  end

  describe 'GET /api/v1/trends/tags and GET /api/v1/trends' do
    let!(:tag) { Fabricate(:tag, name: 'fedibird', trendable: true) }

    before do
      redis.zadd('trending_tags:allowed', 10, tag.id)
    end

    it 'returns the same tag list from the legacy and tags endpoints' do
      get '/api/v1/trends'
      legacy = body_as_json

      get '/api/v1/trends/tags'
      current = body_as_json

      expect(response).to have_http_status(200)
      expect(current).to eq(legacy)
      expect(current.first[:name]).to eq 'fedibird'
      expect(current.first[:history]).to be_an(Array)
    end

    it 'paginates with limit and offset' do
      extra = Fabricate(:tag, name: 'second', trendable: true)
      redis.zadd('trending_tags:allowed', 9, extra.id)

      get '/api/v1/trends/tags', params: { limit: 1 }

      expect(body_as_json.size).to eq 1
      expect(response.headers['Link'].to_s).to include('rel="next"')
    end

    it 'returns an empty list when trends are disabled' do
      Setting.trends = false

      get '/api/v1/trends/tags'

      expect(body_as_json).to eq []
    end
  end

  describe 'GET /api/v1/trends/links' do
    let(:card) do
      Fabricate(:preview_card, trendable: true, language: 'en', link_type: :article, title: 'Hello', description: 'World', provider_name: 'Example', image_description: 'A photo', published_at: Time.utc(2024, 1, 2, 3, 4, 5))
    end

    before do
      PreviewCardTrend.create!(preview_card: card, score: 5, rank: 1, allowed: true, language: 'en')
    end

    it 'returns allowed links with history' do
      get '/api/v1/trends/links'

      expect(response).to have_http_status(200)
      expect(body_as_json.first[:url]).to eq card.url
      expect(body_as_json.first[:language]).to eq 'en'
      expect(body_as_json.first[:image_description]).to eq 'A photo'
      expect(body_as_json.first[:published_at]).to eq '2024-01-02T03:04:05.000Z'
      expect(body_as_json.first[:history]).to be_an(Array)
      expect(response.headers['Cache-Control']).to include('public')
    end

    it 'orders a matching Accept-Language ahead of other locales' do
      other = Fabricate(:preview_card, trendable: true, language: 'ja', link_type: :article, title: '日本語', description: '本文', provider_name: 'Example')
      PreviewCardTrend.create!(preview_card: other, score: 1, rank: 2, allowed: true, language: 'ja')

      get '/api/v1/trends/links', headers: { 'Accept-Language' => 'ja' }

      expect(body_as_json.first[:title]).to eq '日本語'
    end

    it 'returns an empty list when trends are disabled' do
      Setting.trends = false

      get '/api/v1/trends/links'

      expect(body_as_json).to eq []
    end
  end

  describe 'GET /api/v1/trends/statuses' do
    let(:status) { Fabricate(:status, account: account, visibility: :public, language: 'en', text: 'Public hello') }

    before do
      StatusTrend.create!(status: status, account: account, score: 4, rank: 1, allowed: true, language: 'en')
    end

    it 'returns allowed public statuses' do
      get '/api/v1/trends/statuses'

      expect(response).to have_http_status(200)
      expect(body_as_json.first[:id]).to eq status.id.to_s
      expect(response.headers['Cache-Control']).to include('public')
    end

    it 'orders a matching Accept-Language ahead of other locales' do
      ja_account = Fabricate(:account, discoverable: true, trendable: true)
      ja_status = Fabricate(:status, account: ja_account, visibility: :public, language: 'ja', text: 'こんにちは')
      StatusTrend.create!(status: ja_status, account: ja_account, score: 1, rank: 2, allowed: true, language: 'ja')

      get '/api/v1/trends/statuses', headers: { 'Accept-Language' => 'ja' }

      expect(body_as_json.first[:id]).to eq ja_status.id.to_s
    end

    it 'hides statuses from accounts the viewer has blocked' do
      viewer = Fabricate(:user)
      blocked = Fabricate(:account, discoverable: true, trendable: true)
      hidden = Fabricate(:status, account: blocked, visibility: :public, language: 'en', text: 'Hidden')
      StatusTrend.create!(status: hidden, account: blocked, score: 20, rank: 1, allowed: true, language: 'en')
      Fabricate(:block, account: viewer.account, target_account: blocked)
      token = Fabricate(:accessible_access_token, resource_owner_id: viewer.id, scopes: 'read')

      get '/api/v1/trends/statuses', headers: { 'Authorization' => "Bearer #{token.token}" }

      ids = body_as_json.map { |item| item[:id] }
      expect(ids).to include(status.id.to_s)
      expect(ids).not_to include(hidden.id.to_s)
    end

    it 'returns an empty list when trends are disabled' do
      Setting.trends = false

      get '/api/v1/trends/statuses'

      expect(body_as_json).to eq []
    end
  end
end
