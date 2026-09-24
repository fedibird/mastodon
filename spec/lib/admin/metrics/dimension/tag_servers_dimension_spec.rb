# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::TagServersDimension do
  let(:tag)    { Fabricate(:tag) }
  let(:params) { ActionController::Parameters.new(id: tag.id) }

  it 'counts servers that used the tag and honors limit' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      remote = Fabricate(:account, domain: 'remote.example')
      other = Fabricate(:account, domain: 'other.example')
      2.times do
        status = Fabricate(:status, account: remote, created_at: Time.utc(2026, 9, 20, 8, 0, 0))
        status.tags << tag
      end
      other_status = Fabricate(:status, account: other, created_at: Time.utc(2026, 9, 20, 9, 0, 0))
      other_status.tags << tag

      dimension = described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), 10, params)
      expect(dimension.data).to eq [
        { key: 'remote.example', human_key: 'remote.example', value: '2' },
        { key: 'other.example', human_key: 'other.example', value: '1' },
      ]

      limited = described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), 1, params)
      expect(limited.data.map { |row| row[:key] }).to eq ['remote.example']
    end
  end
end
