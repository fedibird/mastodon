# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::MetricsDistributionService do
  let(:now) { Time.now.utc }

  describe 'distribution summaries over a cohort' do
    # Five subjects with contacts_total 0,10,20,30,40 and negative_response_rate
    # 0.0,0.1,0.2,0.3,0.4 in the 24h window, fed through an injected metrics
    # service so the distribution math is tested in isolation.
    let(:subjects) { Array.new(5) { |i| Fabricate(:moderation_subject) }.each_with_index.to_a }

    let(:metrics_service) do
      canned = {}
      subjects.each_with_index do |subject_and_index, index|
        subject, = subject_and_index
        window = { 'contacts_total' => index * 10, 'negative_response_rate' => index / 10.0, 'first_negative_signal_at' => nil }
        canned[subject.id] = { 'windows' => { '24h' => window }, 'lifetime' => window }
      end

      fake = instance_double(Moderation::BehavioralMetricsService)
      allow(fake).to receive(:call) { |subject, **| canned[subject.id] }
      fake
    end

    subject(:result) do
      described_class.new(metrics_service: metrics_service).call(
        subjects.map(&:first),
        now: now,
        windows: { '24h' => 24.hours },
        features: %w(contacts_total negative_response_rate first_negative_signal_at)
      )
    end

    it 'reports the cohort size and the requested features' do
      expect(result['subject_count']).to eq 5
      expect(result['features']).to eq %w(contacts_total negative_response_rate first_negative_signal_at)
      expect(result['windows'].keys).to contain_exactly('24h', 'lifetime')
    end

    it 'summarizes count, nonzero, min, max and mean' do
      summary = result.dig('windows', '24h', 'contacts_total')

      expect(summary['n']).to eq 5
      expect(summary['nonzero']).to eq 4
      expect(summary['min']).to eq 0
      expect(summary['max']).to eq 40
      expect(summary['mean']).to eq 20.0
    end

    it 'computes linear-interpolated percentiles' do
      pct = result.dig('windows', '24h', 'contacts_total', 'percentiles')

      expect(pct[25]).to eq 10.0
      expect(pct[50]).to eq 20.0
      expect(pct[90]).to be_within(1e-9).of(36.0)  # 30 + 0.6*(40-30)
      expect(pct[95]).to be_within(1e-9).of(38.0)
    end

    it 'handles fractional-value features (rates)' do
      summary = result.dig('windows', '24h', 'negative_response_rate')

      expect(summary['max']).to be_within(1e-9).of(0.4)
      expect(summary['percentiles'][50]).to be_within(1e-9).of(0.2)
    end

    it 'skips non-numeric feature values entirely' do
      summary = result.dig('windows', '24h', 'first_negative_signal_at')

      expect(summary['n']).to eq 0
      expect(summary['min']).to be_nil
      expect(summary['percentiles'][50]).to be_nil
    end
  end

  describe 'empty cohort' do
    it 'returns zeroed summaries without error' do
      result = described_class.new.call([], now: now, windows: { '24h' => 24.hours }, features: %w(contacts_total))

      expect(result['subject_count']).to eq 0
      expect(result.dig('windows', '24h', 'contacts_total', 'n')).to eq 0
      expect(result.dig('windows', 'lifetime', 'contacts_total', 'percentiles')[50]).to be_nil
    end
  end

  describe 'end-to-end wiring with the real metrics service' do
    let(:actor) { Fabricate(:account, username: 'dist_actor') }
    let(:other) { Fabricate(:account, username: 'dist_actor_2') }

    before do
      Moderation::EventRecorder.record_interaction(actor: actor, target: Fabricate(:account), event_type: :follow, occurred_at: now - 10.minutes, source_event_key: 'd-1')
      Moderation::EventRecorder.record_interaction(actor: actor, target: Fabricate(:account), event_type: :favourite, occurred_at: now - 5.minutes, source_event_key: 'd-2')
    end

    it 'aggregates real per-subject metrics into a distribution' do
      subjects = [ModerationSubject.find_by(account_id: actor.id), ModerationSubject.for_account!(other)]

      result = described_class.new.call(subjects, now: now, windows: { '24h' => 24.hours })

      # actor has 2 contacts in 24h, other has 0.
      summary = result.dig('windows', '24h', 'contacts_total')
      expect(result['subject_count']).to eq 2
      expect(summary['n']).to eq 2
      expect(summary['max']).to eq 2
      expect(summary['nonzero']).to eq 1
    end
  end
end
