# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Admin::DimensionsController do
  render_views

  let(:user)  { user_with_legacy_role_name('admin') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'admin:read') }
  let(:tag)   { Fabricate(:tag) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    travel_to Time.utc(2026, 9, 21, 12, 0, 0)
  end

  describe 'POST #create' do
    it 'returns requested dimensions, applies limit, and skips unknown keys' do
      Fabricate(:user, locale: 'en', current_sign_in_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:user, locale: 'ja', current_sign_in_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:user, locale: 'ja', current_sign_in_at: Time.utc(2026, 9, 20, 10, 0, 0))
      status = Fabricate(:status, account: Fabricate(:account, domain: 'remote.example'), created_at: Time.utc(2026, 9, 20, 8, 0, 0))
      status.tags << tag

      post :create, params: {
        keys: %w(languages tag_servers nope),
        start_at: Time.utc(2026, 9, 19).iso8601,
        end_at: Time.utc(2026, 9, 22).iso8601,
        limit: 1,
        tag_servers: { id: tag.id },
      }

      expect(response).to have_http_status(200)
      body = body_as_json
      expect(body.map { |row| row[:key] }).to eq %w(languages tag_servers)
      expect(body[0][:data].size).to eq 1
      expect(body[0][:data].first[:key]).to eq 'ja'
      expect(body[1][:data].first[:key]).to eq 'remote.example'
    end

    it 'returns http forbidden without admin:read' do
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }

      post :create, params: { keys: %w(languages) }

      expect(response).to have_http_status(403)
    end

    it 'returns http forbidden without dashboard permission' do
      other = user_with_legacy_role_name('user')
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'admin:read') }

      post :create, params: { keys: %w(languages) }

      expect(response).to have_http_status(403)
    end
  end
end
