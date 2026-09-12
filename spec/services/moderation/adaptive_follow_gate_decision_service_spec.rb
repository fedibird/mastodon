# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::AdaptiveFollowGateDecisionService do
  let(:now) { Time.now.utc }

  GATE_DIMENSIONS = %w(contact_volume velocity rejection report follow_import repeat_behavior).freeze

  def evaluation(**scores)
    subscores = GATE_DIMENSIONS.index_with do |dimension|
      { 'score' => scores.fetch(dimension.to_sym, 0.0), 'reason_codes' => [] }
    end
    { 'policy_version' => 'risk-eval-v0-test', 'params_digest' => 'sha256:test', 'subject_id' => 1, 'generated_at' => now.iso8601, 'subscores' => subscores }
  end

  def decide(canned, context: {}, params: described_class::DEFAULT_PARAMS, policy_version: nil)
    evaluator = instance_double(Moderation::RiskEvaluationService, call: canned)
    described_class.new(evaluator: evaluator, params: params, policy_version: policy_version)
                   .call(ModerationSubject.new.tap { |s| s.id = 1 }, context: context, now: now)
  end

  describe 'output shape' do
    it 'is a shadow, versioned proposal with no execution/deny/action' do
      result = decide(evaluation)

      expect(result['policy_version']).to eq described_class::POLICY_VERSION
      expect(result['params_digest']).to start_with('sha256:')
      expect(result['shadow']).to be true
      expect(result['proposed_friction']).to eq 'allow'
      expect(described_class::FRICTIONS).to_not include('deny')
      expect(result).to_not have_key('action')
      expect(result).to_not have_key('enforcement')
      expect(result).to_not have_key('overall_score')
      expect(result['evaluation']['subscores']).to be_present
    end
  end

  describe 'friction ladder' do
    it 'proposes allow when nothing is elevated' do
      expect(decide(evaluation)['proposed_friction']).to eq 'allow'
    end

    it 'proposes rate_limit for elevated contact volume' do
      result = decide(evaluation(contact_volume: 0.5))
      expect(result['proposed_friction']).to eq 'rate_limit'
      expect(result['matched_rules']).to include(a_hash_including('friction' => 'rate_limit', 'rule' => 'elevated_contact_volume'))
    end

    it 'proposes confirm_target for a local target with multiple independent rejectors' do
      result = decide(evaluation(rejection: 0.5), context: { 'target_locality' => 'local' })
      expect(result['proposed_friction']).to eq 'confirm_target'
      expect(result['matched_rules']).to include(
        a_hash_including('rule' => 'elevated_rejection_local_target', 'conditions' => a_hash_including('rejection' => { 'value' => 0.5, 'minimum' => 0.5 }))
      )
    end

    it 'proposes delay for a remote target with elevated rejection' do
      result = decide(evaluation(rejection: 0.5), context: { 'target_locality' => 'remote' })
      expect(result['proposed_friction']).to eq 'delay'
    end

    it 'proposes delay on high velocity regardless of locality' do
      expect(decide(evaluation(velocity: 0.6), context: { 'target_locality' => 'local' })['proposed_friction']).to eq 'delay'
    end

    it 'proposes moderator_review for sustained rejection with continuation' do
      result = decide(evaluation(rejection: 0.8, repeat_behavior: 0.6))
      expect(result['proposed_friction']).to eq 'moderator_review'
      expect(result['matched_rules']).to include(a_hash_including('friction' => 'moderator_review', 'rule' => 'sustained_rejection_with_continuation'))
    end

    it 'picks the strongest matched friction when several apply' do
      # elevated volume (rate_limit) + high velocity (delay) + sustained rejection (moderator_review)
      result = decide(evaluation(contact_volume: 0.6, velocity: 0.7, rejection: 0.9, repeat_behavior: 0.7))
      expect(result['proposed_friction']).to eq 'moderator_review'
    end
  end

  describe 'behaviour-centric / mechanism-agnostic' do
    it 'does not raise friction based on the follow_import mechanism' do
      result = decide(evaluation, context: { 'mechanism' => 'follow_import', 'target_locality' => 'remote' })
      expect(result['proposed_friction']).to eq 'allow'
      expect(result['context']['mechanism']).to eq 'follow_import'
    end

    it 'echoes but does not use relationship_context for risk' do
      result = decide(evaluation, context: { 'relationship_context' => 'migration_known_follow' })
      expect(result['proposed_friction']).to eq 'allow'
      expect(result['context']['relationship_context']).to eq 'migration_known_follow'
    end

    it 'ignores an unrecognized target_locality value' do
      result = decide(evaluation(rejection: 0.5), context: { 'target_locality' => 'bogus' })
      # Unknown locality is treated as non-local -> delay (not confirm_target).
      expect(result['context']['target_locality']).to be_nil
      expect(result['proposed_friction']).to eq 'delay'
    end
  end

  describe 'guardrails' do
    it 'never escalates on a single block/mute (rejection stays 0)' do
      expect(decide(evaluation(rejection: 0.0), context: { 'target_locality' => 'local' })['proposed_friction']).to eq 'allow'
    end

    it 'never proposes deny' do
      result = decide(evaluation(rejection: 1.0, repeat_behavior: 1.0, velocity: 1.0, contact_volume: 1.0))
      expect(described_class::FRICTIONS).to include(result['proposed_friction'])
      expect(result['proposed_friction']).to eq 'moderator_review'
    end
  end

  describe 'policy versioning' do
    let(:custom_params) do
      params = Marshal.load(Marshal.dump(described_class::DEFAULT_PARAMS))
      params['rate_limit']['contact_volume_min'] = 0.1
      params
    end

    it 'marks custom params and changes the digest' do
      default = decide(evaluation)
      custom  = decide(evaluation, params: custom_params)
      expect(custom['policy_version']).to eq 'custom'
      expect(custom['params_digest']).to_not eq default['params_digest']
    end

    it 'honors an explicit policy_version' do
      expect(decide(evaluation, params: custom_params, policy_version: 'gate-experiment-A')['policy_version']).to eq 'gate-experiment-A'
    end
  end

  describe 'read-only over a real account' do
    it 'proposes allow for an account with no history without writing' do
      account = Fabricate(:account, username: 'gate_fresh')

      result = nil
      expect { result = described_class.new.call(account, context: { 'target_locality' => 'remote' }, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['proposed_friction']).to eq 'allow'
      expect(result['subject_id']).to be_nil
    end
  end
end
