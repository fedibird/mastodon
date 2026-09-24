# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Admin::RetentionController do
  render_views

  let(:user)  { user_with_legacy_role_name('admin') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'admin:read') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    it 'returns daily cohorts with ISO8601 periods and string values' do
      Fabricate(:user, created_at: Time.utc(2026, 9, 1, 8, 0, 0), current_sign_in_at: Time.utc(2026, 9, 3, 8, 0, 0))
      Fabricate(:user, created_at: Time.utc(2026, 9, 1, 9, 0, 0), current_sign_in_at: Time.utc(2026, 9, 1, 9, 0, 0))
      Fabricate(:user, created_at: Time.utc(2026, 9, 2, 8, 0, 0), current_sign_in_at: Time.utc(2026, 9, 3, 8, 0, 0))

      post :create, params: { start_at: '2026-09-01', end_at: '2026-09-03', frequency: 'day' }

      expect(response).to have_http_status(200)
      body = body_as_json
      expect(body.map { |row| row[:period] }).to eq %w(2026-09-01 2026-09-02 2026-09-03)
      expect(body).to all(include(frequency: 'day'))

      september_first = body[0][:data]
      expect(september_first).to eq [
        { date: '2026-09-01', rate: 1.0, value: '2' },
        { date: '2026-09-02', rate: 0.5, value: '1' },
        { date: '2026-09-03', rate: 0.5, value: '1' },
      ]
      expect(body[1][:data]).to eq [
        { date: '2026-09-02', rate: 1.0, value: '1' },
        { date: '2026-09-03', rate: 1.0, value: '1' },
      ]
      expect(body[2][:data]).to eq [
        { date: '2026-09-03', rate: 0.0, value: '0' },
      ]
      expect(september_first.first[:value]).to be_a(String)
      expect(september_first.first[:rate]).to be_a(Float)
    end

    it 'falls back to day when frequency is not day or month' do
      post :create, params: { start_at: '2026-09-01', end_at: '2026-09-01', frequency: 'week' }

      expect(response).to have_http_status(200)
      expect(body_as_json.first[:frequency]).to eq 'day'
    end

    it 'returns http forbidden without admin:read' do
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }

      post :create, params: { start_at: '2026-09-01', end_at: '2026-09-01' }

      expect(response).to have_http_status(403)
    end

    it 'returns http forbidden without dashboard permission' do
      other = user_with_legacy_role_name('user')
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'admin:read') }

      post :create, params: { start_at: '2026-09-01', end_at: '2026-09-01' }

      expect(response).to have_http_status(403)
    end
  end
end
