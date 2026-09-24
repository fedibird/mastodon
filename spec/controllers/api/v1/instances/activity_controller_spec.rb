# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::ActivityController, type: :controller do
  describe 'GET #show' do
    it 'returns 200' do
      get :show
      expect(response).to have_http_status(200)
    end

    context '!Setting.activity_api_enabled' do
      it 'returns 404' do
        Setting.activity_api_enabled = false

        get :show
        expect(response).to have_http_status(404)
      end
    end

    it 'includes daily activity for the current week' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        at_time = Time.utc(2026, 9, 21, 8, 0, 0)
        ActivityTracker.new('activity:statuses:local', :basic).add(5, at_time)
        ActivityTracker.new('activity:logins', :unique).add(42, at_time)
        ActivityTracker.new('activity:accounts:local', :basic).add(2, at_time)

        get :show

        expect(body_as_json.size).to eq 12
        expect(body_as_json.first).to include(
          week: Time.utc(2026, 9, 21, 12, 0, 0).to_i.to_s,
          statuses: '5',
          logins: '1',
          registrations: '2'
        )
      end
    end

    it 'includes a legacy weekly key through ActivityTracker#sum' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        redis.set("activity:statuses:local:#{Date.new(2026, 9, 21).cweek}", 7)

        get :show

        expect(body_as_json.first[:statuses]).to eq '7'
      end
    end
  end
end
