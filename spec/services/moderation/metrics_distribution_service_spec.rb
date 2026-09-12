# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::MetricsDistributionService do
  let(:now) { Time.now.utc }

  # A single-window (24h + lifetime) canned metrics payload with all the fields
  # eligibility depends on, so the distribution logic can be tested in isolation.
  def canned(**fields)
    window = {
      'contacts_total'                          => 0,
      'unique_targets'                          => 0,
      'unique_follow_targets'                   => 0,
      'negative_response_rate'                  => 0.0,
      'linked_negative_rate'                    => 0.0,
      'follow_reject_rate'                      => 0.0,
      'first_negative_signal_at'                => nil,
      'new_targets_after_first_negative_signal' => 0,
      'follows_after_first_negative_signal'     => 0,
    }.merge(fields.transform_keys(&:to_s))

    { 'windows' => { '24h' => window }, 'lifetime' => window }
  end

  def fake_service(mapping)
    fake = instance_double(Moderation::BehavioralMetricsService)
    allow(fake).to receive(:call) { |subject, **| mapping.fetch(subject.id) }
    fake
  end

  def distribution(mapping, features:)
    subjects = mapping.keys.map { |id| ModerationSubject.new.tap { |s| s.id = id } }
    described_class.new(metrics_service: fake_service(mapping))
                   .call(subjects, now: now, windows: { '24h' => 24.hours }, features: features)
  end

  describe 'distribution math (always-eligible raw count)' do
    let(:mapping) do
      (0..4).to_h { |i| [i + 1, canned(contacts_total: i * 10, unique_targets: 4)] }
    end

    subject(:summary) { distribution(mapping, features: %w(contacts_total)).dig('windows', '24h', 'contacts_total') }

    it 'summarizes n/excluded_n/nonzero/min/max/mean' do
      expect(summary['n']).to eq 5
      expect(summary['excluded_n']).to eq 0
      expect(summary['nonzero']).to eq 4
      expect(summary['min']).to eq 0
      expect(summary['max']).to eq 40
      expect(summary['mean']).to eq 20.0
    end

    it 'computes linear-interpolated percentiles' do
      pct = summary['percentiles']
      expect(pct[25]).to eq 10.0
      expect(pct[50]).to eq 20.0
      expect(pct[90]).to be_within(1e-9).of(36.0)
      expect(pct[95]).to be_within(1e-9).of(38.0)
    end
  end

  describe 'negative_response_rate eligibility' do
    it 'excludes a subject with no contacts (not-applicable 0) from the distribution' do
      mapping = {
        1 => canned(unique_targets: 0, negative_response_rate: 0.0),
        2 => canned(unique_targets: 5, negative_response_rate: 0.4),
      }

      result = distribution(mapping, features: %w(negative_response_rate))
      summary = result.dig('windows', '24h', 'negative_response_rate')

      expect(result['subject_count']).to eq 2
      expect(summary['n']).to eq 1
      expect(summary['excluded_n']).to eq 1
      expect(summary['max']).to be_within(1e-9).of(0.4)
    end

    it 'includes a contacted subject whose rate is a genuine 0.0' do
      mapping = { 1 => canned(unique_targets: 3, negative_response_rate: 0.0) }

      summary = distribution(mapping, features: %w(negative_response_rate)).dig('windows', '24h', 'negative_response_rate')

      expect(summary['n']).to eq 1
      expect(summary['excluded_n']).to eq 0
      expect(summary['nonzero']).to eq 0
      expect(summary['min']).to eq 0.0
    end
  end

  describe 'follow_reject_rate eligibility' do
    it 'excludes a subject with no followed targets' do
      mapping = {
        1 => canned(unique_follow_targets: 0, follow_reject_rate: 0.0),
        2 => canned(unique_follow_targets: 4, follow_reject_rate: 0.25),
      }

      summary = distribution(mapping, features: %w(follow_reject_rate)).dig('windows', '24h', 'follow_reject_rate')

      expect(summary['n']).to eq 1
      expect(summary['excluded_n']).to eq 1
      expect(summary['max']).to be_within(1e-9).of(0.25)
    end
  end

  describe 'continuation eligibility' do
    it 'excludes a subject that received no negative signal' do
      mapping = { 1 => canned(first_negative_signal_at: nil, new_targets_after_first_negative_signal: 0) }

      summary = distribution(mapping, features: %w(new_targets_after_first_negative_signal)).dig('windows', '24h', 'new_targets_after_first_negative_signal')

      expect(summary['n']).to eq 0
      expect(summary['excluded_n']).to eq 1
    end

    it 'includes a subject with a negative signal but zero continuation as a genuine 0' do
      mapping = { 1 => canned(first_negative_signal_at: now.iso8601, new_targets_after_first_negative_signal: 0) }

      summary = distribution(mapping, features: %w(new_targets_after_first_negative_signal)).dig('windows', '24h', 'new_targets_after_first_negative_signal')

      expect(summary['n']).to eq 1
      expect(summary['excluded_n']).to eq 0
      expect(summary['nonzero']).to eq 0
      expect(summary['min']).to eq 0
    end
  end

  describe 'de-duplication of subjects' do
    it 'counts a repeated subject only once' do
      s = ModerationSubject.new.tap { |subject| subject.id = 99 }
      mapping = { 99 => canned(contacts_total: 7, unique_targets: 2) }
      service = described_class.new(metrics_service: fake_service(mapping))

      result = service.call([s, s], now: now, windows: { '24h' => 24.hours }, features: %w(contacts_total))

      expect(result['subject_count']).to eq 1
      expect(result.dig('windows', '24h', 'contacts_total', 'n')).to eq 1
      expect(result.dig('windows', '24h', 'contacts_total', 'max')).to eq 7
    end
  end

  describe 'empty cohort' do
    it 'returns zeroed summaries without error' do
      result = described_class.new.call([], now: now, windows: { '24h' => 24.hours }, features: %w(contacts_total))

      expect(result['subject_count']).to eq 0
      expect(result.dig('windows', '24h', 'contacts_total', 'n')).to eq 0
      expect(result.dig('windows', '24h', 'contacts_total', 'excluded_n')).to eq 0
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

    it 'aggregates real per-subject metrics and applies eligibility' do
      subjects = [ModerationSubject.find_by(account_id: actor.id), ModerationSubject.for_account!(other)]

      result = described_class.new.call(subjects, now: now, windows: { '24h' => 24.hours })

      contacts = result.dig('windows', '24h', 'contacts_total')
      expect(result['subject_count']).to eq 2
      expect(contacts['n']).to eq 2
      expect(contacts['max']).to eq 2
      expect(contacts['nonzero']).to eq 1

      # actor has contacts (eligible, rate 0.0); other has none (excluded).
      rate = result.dig('windows', '24h', 'negative_response_rate')
      expect(rate['n']).to eq 1
      expect(rate['excluded_n']).to eq 1
    end
  end
end
