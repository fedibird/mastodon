# frozen_string_literal: true

require 'rails_helper'

describe Api::V1::Admin::MeasuresController do
  render_views

  let(:user)  { user_with_legacy_role_name('admin') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'admin:read') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    let(:tag) { Fabricate(:tag) }

    before do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0)
      ActivityTracker.new('activity:logins', :unique).add(4, Time.utc(2026, 9, 20, 9, 0, 0))
      ActivityTracker.new('activity:interactions', :basic).add(5, Time.utc(2026, 9, 20, 9, 0, 0))
      Trends::History.new('tags', tag.id).add(9, Time.utc(2026, 9, 20, 9, 0, 0))
    end

    it 'returns measures for several keys and ignores unknown keys' do
      post :create, params: {
        keys: %w(active_users interactions tag_uses nope),
        start_at: Time.utc(2026, 9, 19).iso8601,
        end_at: Time.utc(2026, 9, 21).iso8601,
        tag_uses: { id: tag.id },
      }

      expect(response).to have_http_status(200)
      body = body_as_json
      expect(body.map { |row| row[:key] }).to eq %w(active_users interactions tag_uses)
      expect(body).to all(include(:key, :unit, :total, :previous_total, :data))
      expect(body[0][:total]).to eq '1'
      expect(body[1][:total]).to eq '5'
      expect(body[2][:total]).to eq '1'
      expect(body[0][:data]).to include(date: Time.utc(2026, 9, 20).iso8601, value: '1')
    end

    it 'keeps a cached total after the underlying activity is removed' do
      params = {
        keys: %w(interactions),
        start_at: Time.utc(2026, 9, 19).iso8601,
        end_at: Time.utc(2026, 9, 21).iso8601,
      }

      post :create, params: params
      expect(body_as_json.first[:total]).to eq '5'

      redis.del("activity:interactions:#{Time.utc(2026, 9, 20).beginning_of_day.to_i}")

      post :create, params: params
      expect(body_as_json.first[:total]).to eq '5'
    end

    it 'returns invalid date for a malformed start_at' do
      post :create, params: {
        keys: %w(active_users),
        start_at: 'not-a-date',
        end_at: '2026-09-21',
      }

      expect(response).to have_http_status(422)
      expect(body_as_json).to eq(error: 'Invalid date supplied')
    end

    it 'returns http forbidden without admin:read' do
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }

      post :create, params: { keys: %w(active_users) }

      expect(response).to have_http_status(403)
    end

    it 'returns http forbidden without dashboard permission' do
      other = user_with_legacy_role_name('user')
      allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'admin:read') }

      post :create, params: { keys: %w(active_users) }

      expect(response).to have_http_status(403)
    end
  end
end
