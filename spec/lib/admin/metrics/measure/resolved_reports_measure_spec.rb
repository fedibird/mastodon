# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::ResolvedReportsMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new }

  describe '#total' do
    it 'counts reports resolved in the current period' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        report = Fabricate(:report, created_at: Time.utc(2026, 9, 18, 8, 0, 0))
        report.update!(action_taken_at: Time.utc(2026, 9, 20, 9, 0, 0))
        older = Fabricate(:report, created_at: Time.utc(2026, 9, 10, 8, 0, 0))
        older.update!(action_taken_at: Time.utc(2026, 9, 18, 9, 0, 0))

        expect(measure.total).to eq 1
        expect(measure.previous_total).to eq 1
      end
    end
  end
end
