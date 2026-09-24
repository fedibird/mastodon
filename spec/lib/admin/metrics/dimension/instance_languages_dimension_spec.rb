# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::InstanceLanguagesDimension do
  let(:domain) { 'remote.example' }
  let(:params) { ActionController::Parameters.new(domain: domain) }

  it 'counts original statuses by language and skips reblogs' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      account = Fabricate(:account, domain: domain)
      original = Fabricate(:status, account: account, language: 'ja', created_at: Time.utc(2026, 9, 20, 8, 0, 0))
      Fabricate(:status, account: account, language: 'ja', created_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:status, account: account, language: 'en', created_at: Time.utc(2026, 9, 20, 10, 0, 0))
      Fabricate(:status, account: account, language: 'ja', reblog: original, created_at: Time.utc(2026, 9, 20, 11, 0, 0))

      dimension = described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), 10, params)
      expect(dimension.data).to eq [
        { key: 'ja', human_key: 'Japanese', value: '2' },
        { key: 'en', human_key: 'English', value: '1' },
      ]
    end
  end
end
