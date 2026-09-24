# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin Trends API' do # rubocop:disable Metrics/BlockLength
  def auth_headers(token)
    { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' }
  end

  def token_for(user, scopes)
    Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes)
  end

  def role_with(*permissions)
    UserRole.create!(
      name: "Trends #{permissions.join('-')} #{SecureRandom.hex(4)}",
      position: UserRole.maximum(:position).to_i + 1,
      permissions_as_keys: permissions.map(&:to_s)
    )
  end

  let(:taxonomist) { user_with_role(role_with(:manage_taxonomies), account: Fabricate(:account, username: 'taxonomist')) }
  let(:reporter) { user_with_role(role_with(:manage_reports), account: Fabricate(:account, username: 'reporter')) }
  let(:headers) { auth_headers(token_for(taxonomist, 'admin:read admin:write')) }
  let(:reporter_headers) { auth_headers(token_for(reporter, 'admin:read admin:write')) }

  before do
    Setting.trends = true
    Rails.cache.clear
  end

  describe 'GET /api/v1/admin/trends/tags' do
    let!(:visible) { Fabricate(:tag, name: 'visible', display_name: 'Visible', trendable: true, reviewed_at: Time.utc(2024, 1, 1)) }
    let!(:pending) { Fabricate(:tag, name: 'pending', display_name: 'Pending', trendable: false, reviewed_at: nil) }

    before do
      redis.zadd('trending_tags:all', 20, pending.id)
      redis.zadd('trending_tags:all', 10, visible.id)
      redis.zadd('trending_tags:allowed', 10, visible.id)
    end

    it 'returns every candidate with the admin serializer for manage_taxonomies' do
      get '/api/v1/admin/trends/tags', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |tag| tag[:name] }).to eq %w(Pending Visible)
      expect(body_as_json.first[:requires_review]).to be true
      expect(body_as_json.first[:trendable]).to be false
      expect(body_as_json.first).not_to have_key(:following)
      expect(body_as_json.first[:id]).to eq(pending.id.to_s)
    end

    it 'falls back to the public allowed set without manage_taxonomies' do
      get '/api/v1/admin/trends/tags', headers: reporter_headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |tag| tag[:name] }).to eq %w(visible)
      expect(body_as_json.first).not_to have_key(:requires_review)
      expect(body_as_json.first).not_to have_key(:trendable)
      expect(body_as_json.first[:following]).to be false
    end

    it 'still lists candidates when trends are disabled for a taxonomist' do
      Setting.trends = false

      get '/api/v1/admin/trends/tags', headers: headers

      expect(body_as_json.map { |tag| tag[:name] }).to eq %w(Pending Visible)
    end

    it 'returns an empty list when trends are disabled and the caller cannot manage taxonomies' do
      Setting.trends = false

      get '/api/v1/admin/trends/tags', headers: reporter_headers

      expect(body_as_json).to eq []
    end

    it 'rejects a token without admin:read' do
      get '/api/v1/admin/trends/tags', headers: auth_headers(token_for(taxonomist, 'write:statuses'))

      expect(response).to have_http_status(403)
    end

    it 'rejects a missing token' do
      get '/api/v1/admin/trends/tags', headers: { 'Accept' => 'application/json' }

      expect(response).to have_http_status(401)
    end
  end

  describe 'POST /api/v1/admin/trends/tags/:id/approve and reject' do
    let!(:tag) { Fabricate(:tag, name: 'reviewme', trendable: nil, reviewed_at: nil) }

    it 'approves the tag and records reviewed_at' do
      post "/api/v1/admin/trends/tags/#{tag.id}/approve", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to be true
      expect(body_as_json[:requires_review]).to be false
      expect(body_as_json[:name]).to eq 'reviewme'
      tag.reload
      expect(tag[:trendable]).to be true
      expect(tag.reviewed_at).to be_present
    end

    it 'rejects the tag and records reviewed_at' do
      post "/api/v1/admin/trends/tags/#{tag.id}/reject", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to be false
      expect(body_as_json[:requires_review]).to be false
      tag.reload
      expect(tag[:trendable]).to be false
      expect(tag.reviewed_at).to be_present
    end

    it 'requires manage_taxonomies' do
      post "/api/v1/admin/trends/tags/#{tag.id}/approve", headers: reporter_headers

      expect(response).to have_http_status(403)
      expect(tag.reload.reviewed_at).to be_nil
    end

    it 'requires admin:write' do
      post "/api/v1/admin/trends/tags/#{tag.id}/approve", headers: auth_headers(token_for(taxonomist, 'admin:read'))

      expect(response).to have_http_status(403)
    end

    it 'returns not found for a missing tag' do
      post '/api/v1/admin/trends/tags/-1/approve', headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'GET /api/v1/admin/trends/links' do
    let!(:allowed_card) do
      Fabricate(:preview_card, trendable: true, language: 'en', title: 'Allowed', description: 'Shown', provider_name: 'Example')
    end
    let!(:pending_card) do
      Fabricate(:preview_card, trendable: nil, language: 'en', title: 'Pending', description: 'Hidden', provider_name: 'Example')
    end

    before do
      PreviewCardTrend.create!(preview_card: allowed_card, score: 5, rank: 2, allowed: true, language: 'en')
      PreviewCardTrend.create!(preview_card: pending_card, score: 9, rank: 1, allowed: false, language: 'en')
    end

    it 'returns unapproved links with requires_review for manage_taxonomies' do
      get '/api/v1/admin/trends/links', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |link| link[:title] }).to eq %w(Pending Allowed)
      expect(body_as_json.first[:id]).to eq pending_card.id
      expect(body_as_json.first[:requires_review]).to be true
      expect(body_as_json.first[:history]).to be_an(Array)
    end

    it 'falls back to allowed public links without manage_taxonomies' do
      get '/api/v1/admin/trends/links', headers: reporter_headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |link| link[:title] }).to eq %w(Allowed)
      expect(body_as_json.first).not_to have_key(:requires_review)
      expect(body_as_json.first).not_to have_key(:id)
    end

    it 'still lists candidates when trends are disabled for a taxonomist' do
      Setting.trends = false

      get '/api/v1/admin/trends/links', headers: headers

      expect(body_as_json.map { |link| link[:title] }).to eq %w(Pending Allowed)
    end

    it 'returns an empty list when trends are disabled and the caller cannot manage taxonomies' do
      Setting.trends = false

      get '/api/v1/admin/trends/links', headers: reporter_headers

      expect(body_as_json).to eq []
    end

    it 'rejects a token without admin:read' do
      get '/api/v1/admin/trends/links', headers: auth_headers(token_for(taxonomist, 'read'))

      expect(response).to have_http_status(403)
    end
  end

  describe 'POST /api/v1/admin/trends/links/:id/approve and reject' do
    let!(:link) { Fabricate(:preview_card, trendable: nil, title: 'Review') }

    it 'approves by setting trendable only' do
      post "/api/v1/admin/trends/links/#{link.id}/approve", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:requires_review]).to be false
      expect(link.reload[:trendable]).to be true
      expect(link.attributes).not_to have_key('reviewed_at')
    end

    it 'rejects by setting trendable only' do
      post "/api/v1/admin/trends/links/#{link.id}/reject", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:requires_review]).to be false
      expect(link.reload[:trendable]).to be false
    end

    it 'requires manage_taxonomies and admin:write' do
      post "/api/v1/admin/trends/links/#{link.id}/approve", headers: reporter_headers
      expect(response).to have_http_status(403)

      post "/api/v1/admin/trends/links/#{link.id}/reject", headers: auth_headers(token_for(taxonomist, 'admin:read'))
      expect(response).to have_http_status(403)
      expect(link.reload[:trendable]).to be_nil
    end

    it 'returns not found for a missing link' do
      post '/api/v1/admin/trends/links/-1/reject', headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'GET /api/v1/admin/trends/statuses' do
    let(:allowed_account) { Fabricate(:account, discoverable: true, trendable: true, reviewed_at: Time.utc(2024, 1, 1)) }
    let(:pending_account) { Fabricate(:account, discoverable: true, trendable: nil, reviewed_at: nil) }
    let!(:allowed_status) { Fabricate(:status, account: allowed_account, visibility: :public, language: 'en', text: 'Allowed status') }
    let!(:pending_status) { Fabricate(:status, account: pending_account, visibility: :public, language: 'en', text: 'Pending status', trendable: nil) }

    before do
      StatusTrend.create!(status: allowed_status, account: allowed_account, score: 4, rank: 2, allowed: true, language: 'en')
      StatusTrend.create!(status: pending_status, account: pending_account, score: 8, rank: 1, allowed: false, language: 'en')
    end

    it 'returns unapproved statuses with requires_review for manage_taxonomies' do
      get '/api/v1/admin/trends/statuses', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |status| status[:id] }).to eq [pending_status.id.to_s, allowed_status.id.to_s]
      expect(body_as_json.first[:requires_review]).to be true
      expect(body_as_json.second[:requires_review]).to be false
    end

    it 'falls back to allowed public statuses without manage_taxonomies' do
      get '/api/v1/admin/trends/statuses', headers: reporter_headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |status| status[:id] }).to eq [allowed_status.id.to_s]
      expect(body_as_json.first).not_to have_key(:requires_review)
    end

    it 'still lists candidates when trends are disabled for a taxonomist' do
      Setting.trends = false

      get '/api/v1/admin/trends/statuses', headers: headers

      expect(body_as_json.map { |status| status[:id] }).to eq [pending_status.id.to_s, allowed_status.id.to_s]
    end

    it 'returns an empty list when trends are disabled and the caller cannot manage taxonomies' do
      Setting.trends = false

      get '/api/v1/admin/trends/statuses', headers: reporter_headers

      expect(body_as_json).to eq []
    end

    it 'rejects a token without admin:read' do
      get '/api/v1/admin/trends/statuses', headers: auth_headers(token_for(taxonomist, 'read:statuses'))

      expect(response).to have_http_status(403)
    end
  end

  describe 'POST /api/v1/admin/trends/statuses/:id/approve and reject' do
    let(:account) { Fabricate(:account) }
    let!(:status) { Fabricate(:status, account: account, trendable: nil) }

    it 'approves by setting trendable only' do
      post "/api/v1/admin/trends/statuses/#{status.id}/approve", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq status.id.to_s
      expect(body_as_json[:requires_review]).to be false
      expect(status.reload[:trendable]).to be true
      expect(status.attributes).not_to have_key('reviewed_at')
    end

    it 'rejects by setting trendable only' do
      post "/api/v1/admin/trends/statuses/#{status.id}/reject", headers: headers

      expect(response).to have_http_status(200)
      expect(status.reload[:trendable]).to be false
    end

    it 'requires manage_taxonomies and admin:write' do
      post "/api/v1/admin/trends/statuses/#{status.id}/approve", headers: reporter_headers
      expect(response).to have_http_status(403)

      post "/api/v1/admin/trends/statuses/#{status.id}/reject", headers: auth_headers(token_for(taxonomist, 'admin:read'))
      expect(response).to have_http_status(403)
      expect(status.reload[:trendable]).to be_nil
    end

    it 'returns not found for a missing status' do
      post '/api/v1/admin/trends/statuses/-1/approve', headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'GET /api/v1/admin/trends/links/publishers' do
    let!(:older) { PreviewCardProvider.create!(domain: 'older.example', trendable: true, reviewed_at: Time.utc(2024, 1, 1), requested_review_at: Time.utc(2023, 12, 1)) }
    let!(:newer) { PreviewCardProvider.create!(domain: 'newer.example', trendable: nil, reviewed_at: nil, requested_review_at: Time.utc(2024, 2, 1)) }

    it 'requires manage_taxonomies and does not fall back to a public list' do
      get '/api/v1/admin/trends/links/publishers', headers: reporter_headers

      expect(response).to have_http_status(403)
    end

    it 'returns providers newest first with review fields' do
      get '/api/v1/admin/trends/links/publishers', headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |provider| provider[:domain] }).to eq ['newer.example', 'older.example']
      expect(body_as_json.first.keys).to contain_exactly(:id, :domain, :trendable, :reviewed_at, :requested_review_at, :requires_review)
      expect(body_as_json.first[:requires_review]).to be true
      expect(body_as_json.first[:trendable]).to be_nil
      expect(body_as_json.second[:requires_review]).to be false
    end

    it 'paginates by id with Link headers' do
      get '/api/v1/admin/trends/links/publishers', headers: headers, params: { limit: 1 }

      expect(body_as_json.map { |provider| provider[:id] }).to eq [newer.id]
      links = LinkHeader.parse(response.headers['Link'].to_s)
      expect(links.find_link(%w(rel next)).href).to eq api_v1_admin_trends_links_preview_card_providers_url(limit: 1, max_id: newer.id)
      expect(links.find_link(%w(rel prev)).href).to eq api_v1_admin_trends_links_preview_card_providers_url(limit: 1, min_id: newer.id)

      get '/api/v1/admin/trends/links/publishers', headers: headers, params: { max_id: newer.id }
      expect(body_as_json.map { |provider| provider[:domain] }).to eq ['older.example']

      get '/api/v1/admin/trends/links/publishers', headers: headers, params: { since_id: older.id }
      expect(body_as_json.map { |provider| provider[:domain] }).to eq ['newer.example']

      get '/api/v1/admin/trends/links/publishers', headers: headers, params: { min_id: older.id }
      expect(body_as_json.map { |provider| provider[:domain] }).to eq ['newer.example']
    end

    it 'rejects a token without admin:read' do
      get '/api/v1/admin/trends/links/publishers', headers: auth_headers(token_for(taxonomist, 'read'))

      expect(response).to have_http_status(403)
    end
  end

  describe 'POST /api/v1/admin/trends/links/publishers/:id/approve and reject' do
    let!(:provider) { PreviewCardProvider.create!(domain: 'publisher.example', trendable: nil, reviewed_at: nil) }

    it 'approves the provider and records reviewed_at' do
      post "/api/v1/admin/trends/links/publishers/#{provider.id}/approve", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:domain]).to eq 'publisher.example'
      expect(body_as_json[:trendable]).to be true
      expect(body_as_json[:requires_review]).to be false
      expect(body_as_json[:reviewed_at]).to be_present
      provider.reload
      expect(provider[:trendable]).to be true
      expect(provider.reviewed_at).to be_present
    end

    it 'rejects the provider and records reviewed_at' do
      post "/api/v1/admin/trends/links/publishers/#{provider.id}/reject", headers: headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to be false
      expect(body_as_json[:requires_review]).to be false
      provider.reload
      expect(provider[:trendable]).to be false
      expect(provider.reviewed_at).to be_present
    end

    it 'requires manage_taxonomies and admin:write' do
      post "/api/v1/admin/trends/links/publishers/#{provider.id}/approve", headers: reporter_headers
      expect(response).to have_http_status(403)

      post "/api/v1/admin/trends/links/publishers/#{provider.id}/reject", headers: auth_headers(token_for(taxonomist, 'admin:read'))
      expect(response).to have_http_status(403)
      expect(provider.reload.reviewed_at).to be_nil
    end

    it 'returns not found for a missing provider' do
      post '/api/v1/admin/trends/links/publishers/-1/approve', headers: headers

      expect(response).to have_http_status(404)
    end
  end
end
