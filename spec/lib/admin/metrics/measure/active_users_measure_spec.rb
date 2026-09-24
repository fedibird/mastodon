# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::ActiveUsersMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new }

  describe '#total and #data' do
    it 'counts unique daily logins and includes a zero day' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        tracker = ActivityTracker.new('activity:logins', :unique)
        tracker.add(7, Time.utc(2026, 9, 19, 9, 0, 0))
        tracker.add(7, Time.utc(2026, 9, 19, 10, 0, 0))
        tracker.add(8, Time.utc(2026, 9, 20, 9, 0, 0))

        expect(measure.total).to eq 2
        expect(measure.previous_total).to eq 0
        expect(measure.data).to eq [
          { 'date' => Time.utc(2026, 9, 19).iso8601, 'value' => '1' },
          { 'date' => Time.utc(2026, 9, 20).iso8601, 'value' => '1' },
        ]
      end
    end
  end
end
