# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::InteractionsMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new }

  describe '#total and #data' do
    it 'sums daily interaction counters' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        tracker = ActivityTracker.new('activity:interactions', :basic)
        tracker.add(3, Time.utc(2026, 9, 19, 9, 0, 0))
        tracker.add(4, Time.utc(2026, 9, 20, 9, 0, 0))

        expect(measure.total).to eq 7
        expect(measure.previous_total).to eq 0
        expect(measure.data).to eq [
          { 'date' => Time.utc(2026, 9, 19).iso8601, 'value' => '3' },
          { 'date' => Time.utc(2026, 9, 20).iso8601, 'value' => '4' },
        ]

        redis.del("activity:interactions:#{Time.utc(2026, 9, 19).beginning_of_day.to_i}")
        redis.del("activity:interactions:#{Time.utc(2026, 9, 20).beginning_of_day.to_i}")
        cached = described_class.new(start_at, end_at, params)
        expect(cached.total).to eq 7
      end
    end
  end
end
