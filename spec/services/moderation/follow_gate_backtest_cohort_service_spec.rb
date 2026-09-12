# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::FollowGateBacktestCohortService do
  # A per-subject backtest result, keyed by subject id via an injected backtest.
  def backtest_result(follow_attempts:, first_friction: {}, truncated: false, gate_policy_version: 'gate-test', gate_params_digest: 'sha256:test')
    {
      'follow_attempts'     => follow_attempts,
      'first_friction'      => first_friction,
      'truncated'           => truncated,
      'gate_policy_version' => gate_policy_version,
      'gate_params_digest'  => gate_params_digest,
    }
  end

  def friction_at(index, minutes)
    { 'attempt_index' => index, 'minutes_from_first_follow' => minutes }
  end

  def cohort(results_by_id)
    subjects = results_by_id.keys.map { |id| ModerationSubject.new.tap { |s| s.id = id } }
    backtest = instance_double(Moderation::FollowGateBacktestService)
    allow(backtest).to receive(:call) { |subject, **| results_by_id.fetch(subject.id) }
    described_class.new(backtest_service: backtest).call(subjects)
  end

  describe 'reach rates and first-friction distributions' do
    subject(:result) do
      cohort(
        1 => backtest_result(follow_attempts: 100, first_friction: { 'delay' => friction_at(10, 5.0) }),
        2 => backtest_result(follow_attempts: 100, first_friction: { 'delay' => friction_at(30, 25.0), 'moderator_review' => friction_at(50, 60.0) }),
        3 => backtest_result(follow_attempts: 100, first_friction: {}) # never reaches friction
      )
    end

    it 'counts the cohort and subjects with follows' do
      expect(result['subject_count']).to eq 3
      expect(result['subjects_with_follows']).to eq 3
      expect(result['gate_policy_version']).to eq 'gate-test'
    end

    it 'reports reach counts and rates per friction (denominator = eligible subjects)' do
      delay = result['frictions']['delay']
      expect(delay['subjects_reached']).to eq 2
      expect(delay['subjects_eligible']).to eq 3
      expect(delay['subjects_censored']).to eq 0
      expect(delay['reach_rate']).to be_within(1e-9).of(2.0 / 3)

      review = result['frictions']['moderator_review']
      expect(review['subjects_reached']).to eq 1
      expect(review['reach_rate']).to be_within(1e-9).of(1.0 / 3)

      expect(result['frictions']['rate_limit']['subjects_reached']).to eq 0
      expect(result['frictions']['rate_limit']['reach_rate']).to eq 0.0
    end

    it 'does not report the unsupported confirm_target as a friction tier' do
      expect(result['frictions']).to_not have_key('confirm_target')
      expect(result['unsupported_frictions']).to have_key('confirm_target')
    end

    it 'summarizes first-friction attempt index and timing distributions' do
      delay = result['frictions']['delay']
      expect(delay['first_attempt_index']).to include('n' => 2, 'min' => 10, 'max' => 30, 'mean' => 20.0)
      expect(delay['first_minutes_from_follow']).to include('min' => 5.0, 'max' => 25.0)
    end
  end

  describe 'subjects with no follows' do
    it 'excludes them from the reach-rate denominator but counts them in subject_count' do
      result = cohort(
        1 => backtest_result(follow_attempts: 0, first_friction: {}),
        2 => backtest_result(follow_attempts: 40, first_friction: { 'rate_limit' => friction_at(5, 2.0) })
      )

      expect(result['subject_count']).to eq 2
      expect(result['subjects_with_follows']).to eq 1
      expect(result['frictions']['rate_limit']['reach_rate']).to eq 1.0
    end
  end

  describe 'right-censoring of truncated backtests' do
    # A: complete run, delay not reached  -> eligible, definitive non-reach
    # B: truncated run, delay not reached  -> censored, excluded from denominator
    # C: truncated run, delay reached       -> reached + eligible
    subject(:delay) do
      cohort(
        1 => backtest_result(follow_attempts: 50, truncated: false, first_friction: {}),
        2 => backtest_result(follow_attempts: 2000, truncated: true, first_friction: {}),
        3 => backtest_result(follow_attempts: 2000, truncated: true, first_friction: { 'delay' => friction_at(120, 40.0) })
      )['frictions']['delay']
    end

    it 'excludes the truncated non-reacher and keeps reached/complete as eligible' do
      expect(delay['subjects_reached']).to eq 1   # C
      expect(delay['subjects_eligible']).to eq 2  # A + C
      expect(delay['subjects_censored']).to eq 1  # B
      expect(delay['reach_rate']).to be_within(1e-9).of(1.0 / 2)
    end
  end

  describe 'policy consistency' do
    it 'flags a mixed policy across the cohort' do
      result = cohort(
        1 => backtest_result(follow_attempts: 10, gate_policy_version: 'gate-A', gate_params_digest: 'sha256:a'),
        2 => backtest_result(follow_attempts: 10, gate_policy_version: 'gate-B', gate_params_digest: 'sha256:b')
      )

      expect(result['mixed_policy']).to be true
      expect(result['gate_policy_version']).to eq 'mixed'
    end

    it 'reports the single policy when consistent' do
      result = cohort(
        1 => backtest_result(follow_attempts: 10),
        2 => backtest_result(follow_attempts: 10)
      )

      expect(result['mixed_policy']).to be false
      expect(result['gate_policy_version']).to eq 'gate-test'
    end
  end

  describe 'de-duplication' do
    it 'counts a repeated subject once' do
      backtest = instance_double(Moderation::FollowGateBacktestService)
      allow(backtest).to receive(:call).and_return(backtest_result(follow_attempts: 10, first_friction: { 'delay' => friction_at(3, 1.0) }))
      s = ModerationSubject.new.tap { |subject| subject.id = 7 }

      result = described_class.new(backtest_service: backtest).call([s, s])

      expect(result['subject_count']).to eq 1
      expect(result['subjects_with_follows']).to eq 1
      expect(result['frictions']['delay']['subjects_reached']).to eq 1
    end
  end

  describe 'empty cohort' do
    it 'returns zeroed aggregates without error' do
      result = described_class.new.call([])

      expect(result['subject_count']).to eq 0
      expect(result['subjects_with_follows']).to eq 0
      expect(result['frictions']['delay']['subjects_reached']).to eq 0
      expect(result['frictions']['delay']['first_attempt_index']['n']).to eq 0
    end
  end

  describe 'end-to-end with the real backtest service' do
    it 'aggregates a low-risk cohort as never reaching friction' do
      actor = Fabricate(:account, username: 'cohort_real')
      Moderation::EventRecorder.record_interaction(actor: actor, target: Fabricate(:account), event_type: :follow, occurred_at: 1.hour.ago, source_event_key: 'c-1')
      subject = ModerationSubject.find_by(account_id: actor.id)

      result = described_class.new.call([subject])

      expect(result['subjects_with_follows']).to eq 1
      expect(result['frictions'].values.map { |f| f['subjects_reached'] }).to all(eq(0))
    end
  end
end
