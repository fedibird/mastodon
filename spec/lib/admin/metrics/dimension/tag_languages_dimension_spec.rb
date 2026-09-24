# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::TagLanguagesDimension do
  let(:tag)    { Fabricate(:tag) }
  let(:params) { ActionController::Parameters.new(id: tag.id) }

  it 'counts languages on tagged statuses' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      ja = Fabricate(:status, language: 'ja', created_at: Time.utc(2026, 9, 20, 8, 0, 0))
      en = Fabricate(:status, language: 'en', created_at: Time.utc(2026, 9, 20, 9, 0, 0))
      ja.tags << tag
      Fabricate(:status, language: 'ja', created_at: Time.utc(2026, 9, 20, 10, 0, 0)).tags << tag
      en.tags << tag

      dimension = described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), 10, params)
      expect(dimension.data).to eq [
        { key: 'ja', human_key: 'Japanese', value: '2' },
        { key: 'en', human_key: 'English', value: '1' },
      ]
    end
  end
end
