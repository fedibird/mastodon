# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Measure::TagAccountsMeasure do
  subject(:measure) { described_class.new(start_at, end_at, params) }

  let!(:tag) { Fabricate(:tag) }

  let(:start_at) { 2.days.ago }
  let(:end_at)   { Time.now.utc }
  let(:params) { ActionController::Parameters.new(id: tag.id) }

  describe '#total and #data' do
    it 'counts tag accounts from Trends::History without changing Tag#history' do
      travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
        history = Trends::History.new('tags', tag.id)
        history.add(11, Time.utc(2026, 9, 20, 8, 0, 0))
        history.add(11, Time.utc(2026, 9, 20, 9, 0, 0))
        history.add(12, Time.utc(2026, 9, 20, 10, 0, 0))

        expect(measure.total).to eq 2
        expect(measure.data).to include(date: Time.utc(2026, 9, 20).iso8601, value: '2')
        expect(tag.history).to all(include(:day, :uses, :accounts))
        expect(tag.history).to be_a(Array)
      end
    end
  end
end
