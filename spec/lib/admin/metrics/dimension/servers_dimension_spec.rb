# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::ServersDimension do
  subject(:dimension) { described_class.new(start_at, end_at, limit, params) }

  let(:start_at) { Time.utc(2026, 9, 19) }
  let(:end_at)   { Time.utc(2026, 9, 22) }
  let(:limit)    { 10 }
  let(:params)   { ActionController::Parameters.new }

  it 'counts local and remote servers and excludes statuses outside the range' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      Fabricate(:status, account: Fabricate(:account, domain: nil), created_at: Time.utc(2026, 9, 20, 8, 0, 0))
      remote = Fabricate(:account, domain: 'remote.example')
      Fabricate(:status, account: remote, created_at: Time.utc(2026, 9, 20, 9, 0, 0))
      Fabricate(:status, account: remote, created_at: Time.utc(2026, 9, 20, 10, 0, 0))
      Fabricate(:status, account: Fabricate(:account, domain: 'old.example'), created_at: Time.utc(2026, 8, 1, 8, 0, 0))

      expect(dimension.data).to eq [
        { key: 'remote.example', human_key: 'remote.example', value: '2' },
        { key: Rails.configuration.x.local_domain, human_key: Rails.configuration.x.local_domain, value: '1' },
      ]

      limited = described_class.new(start_at, end_at, 1, params)
      expect(limited.data.map { |row| row[:key] }).to eq ['remote.example']
    end
  end
end
