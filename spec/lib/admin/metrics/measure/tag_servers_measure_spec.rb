# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::TagServersMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let!(:tag) { Fabricate(:tag) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new(id: tag.id) }

  describe '#total' do
    it 'counts distinct servers that used the tag' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        status = Fabricate(:status, account: Fabricate(:account, domain: 'example.com'), created_at: Time.utc(2026, 9, 20, 8, 0, 0))
        status.tags << tag
        Fabricate(:status, account: Fabricate(:account, domain: 'example.com'), created_at: Time.utc(2026, 9, 20, 9, 0, 0)).tags << tag

        ranged = described_class.new(Time.utc(2026, 9, 19), 1.second.from_now, params)
        expect(ranged.total).to eq 1
        expect(measure.data).to all(include(:date, :value))
      end
    end
  end
end
