# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::ModeratorRecommendationService do
  let(:now) { Time.now.utc }

  DIMENSIONS = %w(contact_volume velocity rejection report follow_import repeat_behavior).freeze

  # Build a canned RiskEvaluationService output with the given sub-score values.
  # +extra+ injects additional (possibly unknown) dimensions.
  def evaluation(extra: {}, **scores)
    subscores = DIMENSIONS.index_with do |dimension|
      { 'score' => scores.fetch(dimension.to_sym, 0.0), 'reason_codes' => [] }
    end
    extra.each { |dimension, score| subscores[dimension.to_s] = { 'score' => score, 'reason_codes' => [] } }

    {
      'policy_version' => 'risk-eval-v0-test',
      'params_digest'  => 'sha256:test',
      'subject_id'     => 1,
      'generated_at'   => now.iso8601,
      'subscores'      => subscores,
    }
  end

  def recommend(canned, params: described_class::DEFAULT_PARAMS, policy_version: nil)
    evaluator = instance_double(Moderation::RiskEvaluationService, call: canned)
    described_class.new(evaluator: evaluator, params: params, policy_version: policy_version)
                   .call(ModerationSubject.new.tap { |s| s.id = 1 }, now: now)
  end

  describe 'output shape' do
    it 'is advisory, versioned, and carries no enforcement/action' do
      result = recommend(evaluation)

      expect(result['policy_version']).to eq described_class::POLICY_VERSION
      expect(result['params_digest']).to start_with('sha256:')
      expect(result['advisory']).to be true
      expect(result['recommendation']).to eq 'normal'
      expect(result).to_not have_key('action')
      expect(result).to_not have_key('enforcement')
      expect(result).to_not have_key('overall_score')
      # The full evaluation is embedded for auditability.
      expect(result['evaluation']['subscores']).to be_present
    end
  end

  describe 'tiers' do
    it 'recommends normal when nothing is elevated' do
      expect(recommend(evaluation)['recommendation']).to eq 'normal'
    end

    it 'recommends watch for a single elevated dimension' do
      result = recommend(evaluation(contact_volume: 0.5))
      expect(result['recommendation']).to eq 'watch'
      expect(result['matched_rules']).to include(a_hash_including('tier' => 'watch', 'rule' => 'elevated_contact_volume'))
    end

    it 'recommends review_recommended when multiple independent rejectors are present' do
      result = recommend(evaluation(rejection: 0.5))
      expect(result['recommendation']).to eq 'review_recommended'
      expect(result['matched_rules']).to include(
        a_hash_including('rule' => 'multiple_independent_rejectors', 'conditions' => { 'rejection' => { 'value' => 0.5, 'minimum' => 0.5 } })
      )
    end

    it 'recommends review_recommended when a report is present' do
      expect(recommend(evaluation(report: 0.4))['recommendation']).to eq 'review_recommended'
    end

    it 'recommends review_recommended for high volume AND velocity together' do
      result = recommend(evaluation(contact_volume: 0.6, velocity: 0.6))
      expect(result['recommendation']).to eq 'review_recommended'
      expect(result['matched_rules'].map { |r| r['rule'] }).to include('high_volume_and_velocity')
    end

    it 'recommends urgent_review for sustained rejection with continuation' do
      result = recommend(evaluation(rejection: 0.8, repeat_behavior: 0.6))
      expect(result['recommendation']).to eq 'urgent_review'
      expect(result['matched_rules']).to include(a_hash_including('tier' => 'urgent_review', 'rule' => 'sustained_rejection_with_continuation'))
    end

    it 'picks the highest matched tier when several rules fire' do
      # Also matches watch (elevated) and review (multiple rejectors), but urgent wins.
      result = recommend(evaluation(rejection: 0.9, repeat_behavior: 0.7))
      tiers = result['matched_rules'].map { |r| r['tier'] }
      expect(tiers).to include('urgent_review', 'review_recommended', 'watch')
      expect(result['recommendation']).to eq 'urgent_review'
    end
  end

  describe 'guardrails' do
    it 'does not escalate on a single block/mute (rejection sub-score stays 0)' do
      # A single block never raises the rejection sub-score above 0 upstream, so
      # here rejection is 0 and nothing else fires -> normal.
      expect(recommend(evaluation(rejection: 0.0))['recommendation']).to eq 'normal'
    end

    it 'never recommends off the deferred follow_import dimension, even if it scored high' do
      # follow_import is not in the watch allowlist and is used by no rule, so even
      # a leaked high score must not affect the recommendation.
      result = recommend(evaluation(follow_import: 1.0))
      expect(result['recommendation']).to eq 'normal'
      expect(result['matched_rules']).to be_empty
    end

    it 'ignores an unknown/new sub-score dimension until the policy allowlists it' do
      # A brand-new dimension added upstream must not auto-fire watch without a
      # policy change/version bump.
      result = recommend(evaluation(extra: { 'brand_new_signal' => 1.0 }))
      expect(result['recommendation']).to eq 'normal'
      expect(result['matched_rules']).to be_empty
    end
  end

  describe 'policy versioning' do
    let(:custom_params) do
      params = Marshal.load(Marshal.dump(described_class::DEFAULT_PARAMS))
      params['watch']['any_subscore_min'] = 0.1
      params
    end

    it 'marks custom params and changes the digest' do
      default = recommend(evaluation)
      custom  = recommend(evaluation, params: custom_params)

      expect(custom['policy_version']).to eq 'custom'
      expect(custom['params_digest']).to_not eq default['params_digest']
    end

    it 'honors an explicit policy_version' do
      expect(recommend(evaluation, params: custom_params, policy_version: 'reco-experiment-A')['policy_version']).to eq 'reco-experiment-A'
    end
  end

  describe 'read-only over a real account' do
    it 'recommends normal for an account with no history without writing' do
      account = Fabricate(:account, username: 'reco_fresh')

      result = nil
      expect { result = described_class.new.call(account, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['recommendation']).to eq 'normal'
      expect(result['subject_id']).to be_nil
    end
  end
end
