# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::OpenedReportsMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new }

  describe '#total' do
    it 'counts reports opened in the current period' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        Fabricate(:report, created_at: Time.utc(2026, 9, 20, 8, 0, 0))
        Fabricate(:report, created_at: Time.utc(2026, 9, 18, 8, 0, 0))

        expect(measure.total).to eq 1
        expect(measure.previous_total).to eq 1
      end
    end
  end
end
