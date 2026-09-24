# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::LanguagesDimension do
  subject(:dimension) { described_class.new(start_at, end_at, limit, params) }

  let(:start_at) { Time.utc(2026, 9, 19) }
  let(:end_at)   { Time.utc(2026, 9, 22) }
  let(:limit)    { 10 }
  let(:params)   { ActionController::Parameters.new }

  it 'counts active users by locale' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      Fabricate(:user, locale: 'en', current_sign_in_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:user, locale: 'ja', current_sign_in_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:user, locale: 'ja', current_sign_in_at: Time.utc(2026, 9, 20, 10, 0, 0))
      Fabricate(:user, locale: 'de', current_sign_in_at: Time.utc(2026, 8, 1, 9, 0, 0))

      expect(dimension.data).to eq [
        { key: 'ja', human_key: 'Japanese', value: '2' },
        { key: 'en', human_key: 'English', value: '1' },
      ]
    end
  end

  it 'reuses the cached result' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      Fabricate(:user, locale: 'en', current_sign_in_at: Time.utc(2026, 9, 20, 9, 0, 0))
      expect(dimension.data.first[:value]).to eq '1'

      Fabricate(:user, locale: 'en', current_sign_in_at: Time.utc(2026, 9, 20, 11, 0, 0))
      again = described_class.new(start_at, end_at, limit, params)
      expect(again.data.first[:value]).to eq '1'
    end
  end
end
