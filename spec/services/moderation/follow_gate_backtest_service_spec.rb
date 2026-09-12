# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::FollowGateBacktestService do
  let(:actor) { Fabricate(:account, username: 'backtest_actor') }
  let(:t0)    { 3.hours.ago.change(usec: 0) }

  def record_follow(target, at, key)
    Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :follow, occurred_at: at, source_event_key: key)
  end

  describe 'replaying follow attempts as of their own time' do
    # Three follows at t0, t0+30m, t0+90m. An injected gate returns a friction
    # based on the evaluation time, so we can assert timing/index deterministically.
    let!(:follow1) { record_follow(Fabricate(:account, username: 'bt1'), t0, 'bt-1') }
    let!(:follow2) { record_follow(Fabricate(:account, username: 'bt2'), t0 + 30.minutes, 'bt-2') }
    let!(:follow3) { record_follow(Fabricate(:account, username: 'bt3'), t0 + 90.minutes, 'bt-3') }

    let(:gate_service) do
      fake = instance_double(Moderation::AdaptiveFollowGateDecisionService)
      allow(fake).to receive(:call) do |_subject, now:, **|
        friction =
          if now >= t0 + 90.minutes then 'delay'
          elsif now >= t0 + 30.minutes then 'rate_limit'
          else 'allow'
          end
        { 'proposed_friction' => friction, 'policy_version' => 'gate-test', 'params_digest' => 'sha256:test' }
      end
      fake
    end

    subject(:result) { described_class.new(gate_service: gate_service).call(actor) }

    it 'reports the attempts and per-friction counts' do
      expect(result['subject_id']).to eq ModerationSubject.find_by(account_id: actor.id).id
      expect(result['follow_attempts']).to eq 3
      expect(result['friction_counts']).to eq('allow' => 1, 'rate_limit' => 1, 'delay' => 1)
      expect(result['gate_policy_version']).to eq 'gate-test'
    end

    it 'records when each friction tier is first reached (index + time)' do
      expect(result['first_friction']['rate_limit']).to include('attempt_index' => 2, 'minutes_from_first_follow' => 30.0)
      expect(result['first_friction']['delay']).to include('attempt_index' => 3, 'minutes_from_first_follow' => 90.0)
      expect(result['first_friction']).to_not have_key('allow')
    end

    it 'evaluates each attempt as of its own occurred_at (no future leakage)' do
      seen_nows = []
      allow(gate_service).to receive(:call) do |_subject, now:, **|
        seen_nows << now
        { 'proposed_friction' => 'allow', 'policy_version' => 'gate-test', 'params_digest' => 'sha256:test' }
      end

      described_class.new(gate_service: gate_service).call(actor)

      expect(seen_nows.map(&:to_i)).to eq [t0, t0 + 30.minutes, t0 + 90.minutes].map(&:to_i)
    end
  end

  describe 'target locality reconstruction' do
    let(:local_target)  { Fabricate(:account, username: 'bt_local') }
    let(:remote_target) { Fabricate(:account, username: 'bt_remote', domain: 'remote.example', protocol: :activitypub) }

    let!(:local_follow)  { record_follow(local_target, t0, 'loc-1') }
    let!(:remote_follow) { record_follow(remote_target, t0 + 10.minutes, 'loc-2') }

    it 'passes each attempt the target locality restored from the target subject origin' do
      seen = []
      gate = instance_double(Moderation::AdaptiveFollowGateDecisionService)
      allow(gate).to receive(:call) do |_subject, context:, now:|
        seen << [now.to_i, context['target_locality']]
        { 'proposed_friction' => 'allow', 'policy_version' => 'g', 'params_digest' => 's' }
      end

      described_class.new(gate_service: gate).call(actor)

      expect(seen).to eq [[t0.to_i, 'local'], [(t0 + 10.minutes).to_i, 'remote']]
    end

    context 'with the real gate under elevated rejection' do
      # Inject an evaluator into the real gate so rejection is elevated; then the
      # locality-based delay rule must fire for the remote target but NOT the local.
      let(:evaluator) do
        subscores = %w(contact_volume velocity rejection report follow_import repeat_behavior).index_with { |d| { 'score' => d == 'rejection' ? 0.6 : 0.0, 'reason_codes' => [] } }
        instance_double(Moderation::RiskEvaluationService, call: { 'subject_id' => 1, 'subscores' => subscores, 'policy_version' => 'risk-test', 'params_digest' => 'sha256:t' })
      end

      it 'does not fire locality-based delay for a local target, but does for a remote target' do
        gate   = Moderation::AdaptiveFollowGateDecisionService.new(evaluator: evaluator)
        result = described_class.new(gate_service: gate).call(actor)

        # local follow at t0 -> allow (no locality delay); remote follow -> delay.
        expect(result['friction_counts']).to eq('allow' => 1, 'delay' => 1)
        expect(result['first_friction']['delay']).to include('attempt_index' => 2)
      end
    end
  end

  describe 'truncation reporting' do
    it 'reports total vs analyzed and the truncated flag when capped' do
      3.times { |i| record_follow(Fabricate(:account, username: "bt_trunc_#{i}"), t0 + i.minutes, "trunc-#{i}") }

      result = described_class.new.call(actor, max_events: 2)

      expect(result['total_follow_events']).to eq 3
      expect(result['analyzed_follow_events']).to eq 2
      expect(result['follow_attempts']).to eq 2
      expect(result['max_events']).to eq 2
      expect(result['truncated']).to be true
    end
  end

  describe 'a subject with no follows' do
    it 'returns a zeroed result' do
      ModerationSubject.for_account!(actor)
      result = described_class.new.call(actor)

      expect(result['follow_attempts']).to eq 0
      expect(result['friction_counts']).to eq({})
      expect(result['first_friction']).to eq({})
      expect(result['first_follow_at']).to be_nil
    end
  end

  describe 'a low-risk subject with the real gate' do
    it 'proposes allow throughout (no friction ever reached)' do
      record_follow(Fabricate(:account, username: 'bt_real1'), t0, 'btr-1')
      record_follow(Fabricate(:account, username: 'bt_real2'), t0 + 5.minutes, 'btr-2')

      result = described_class.new.call(actor)

      expect(result['follow_attempts']).to eq 2
      expect(result['friction_counts']).to eq('allow' => 2)
      expect(result['first_friction']).to be_empty
    end
  end

  describe 'read-only' do
    it 'does not create a ModerationSubject for an account with no history' do
      fresh = Fabricate(:account, username: 'bt_fresh')

      result = nil
      expect { result = described_class.new.call(fresh) }.to_not change(ModerationSubject, :count)

      expect(result['subject_id']).to be_nil
      expect(result['follow_attempts']).to eq 0
    end
  end
end
