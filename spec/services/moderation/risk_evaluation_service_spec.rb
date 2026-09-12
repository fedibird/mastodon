# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::RiskEvaluationService do
  let(:now) { Time.now.utc }

  WINDOW_DEFAULTS = {
    'contacts_total' => 0, 'unique_targets' => 0, 'follows' => 0, 'unique_follow_targets' => 0,
    'reports_received' => 0, 'unique_negative_responders' => 0, 'linked_negative_responders' => 0,
    'negative_response_rate' => 0.0,
    'first_negative_signal_at' => nil,
    'new_targets_after_first_negative_signal' => 0, 'follows_after_first_negative_signal' => 0,
  }.freeze

  def metrics(windows: {}, follow_import: {})
    full_windows = %w(1h 6h 24h 7d 30d).index_with do |name|
      WINDOW_DEFAULTS.merge((windows[name] || {}).transform_keys(&:to_s))
    end

    {
      'subject_id'            => 1,
      'windows'               => full_windows,
      'lifetime'              => WINDOW_DEFAULTS.dup,
      'follow_import_context' => {
        'batch_count' => 0, 'target_total' => 0, 'unresolved_target_ratio' => 0.0, 'prior_relationship_known_targets' => 0,
      }.merge(follow_import.transform_keys(&:to_s)),
    }
  end

  def evaluate(canned)
    fake = instance_double(Moderation::BehavioralMetricsService, call: canned)
    described_class.new(metrics_service: fake).call(ModerationSubject.new.tap { |s| s.id = 1 }, now: now)
  end

  describe 'output shape' do
    it 'is versioned, keyed by subject, and carries only sub-scores (no action/decision)' do
      result = evaluate(metrics)

      expect(result['policy_version']).to eq described_class::POLICY_VERSION
      expect(result['subject_id']).to eq 1
      expect(result['subscores'].keys).to contain_exactly(
        'contact_volume', 'velocity', 'rejection', 'report', 'follow_import', 'repeat_behavior'
      )
      # Evaluation must not decide or recommend anything.
      expect(result).to_not have_key('action')
      expect(result).to_not have_key('recommendation')
      expect(result).to_not have_key('decision')
      expect(result).to_not have_key('overall_score')
    end

    it 'scores an empty subject at zero on every dimension' do
      result = evaluate(metrics)
      result['subscores'].each_value do |sub|
        expect(sub['score']).to eq 0.0
        expect(sub['reason_codes']).to be_empty
      end
    end
  end

  describe 'contact_volume' do
    it 'fires with an explaining reason code carrying the value and window' do
      result = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 250 } }))
      sub = result['subscores']['contact_volume']

      expect(sub['score']).to eq 0.5
      expect(sub['reason_codes']).to include('code' => 'high_unique_targets_24h', 'value' => 250, 'window' => '24h')
    end
  end

  describe 'velocity' do
    it 'fires on short-window unique targets' do
      sub = evaluate(metrics(windows: { '1h' => { 'unique_targets' => 40 } }))['subscores']['velocity']

      expect(sub['score']).to eq 0.6
      expect(sub['reason_codes'].map { |r| r['code'] }).to include('high_unique_targets_1h')
    end
  end

  describe 'rejection guardrails' do
    it 'does NOT fire for a single independent rejector' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_negative_responders' => 1, 'linked_negative_responders' => 1 } }))['subscores']['rejection']

      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
    end

    it 'fires only once multiple independent responders are present' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_negative_responders' => 6, 'linked_negative_responders' => 6 } }))['subscores']['rejection']

      expect(sub['reason_codes'].map { |r| r['code'] }).to include('multiple_independent_rejectors', 'linked_independent_rejectors')
      expect(sub['score']).to be > 0.0
    end

    it 'ignores negative_response_rate on a tiny contact sample' do
      # rate is high but only 3 unique targets -> below min_unique_targets guard.
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 3, 'negative_response_rate' => 0.9 } }))['subscores']['rejection']

      expect(sub['reason_codes']).to be_empty
    end

    it 'counts an elevated rate once the sample is large enough' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 50, 'negative_response_rate' => 0.3 } }))['subscores']['rejection']

      expect(sub['reason_codes']).to include('code' => 'elevated_negative_response_rate', 'value' => 0.3, 'window' => '24h')
    end
  end

  describe 'report' do
    it 'fires on reports received' do
      sub = evaluate(metrics(windows: { '24h' => { 'reports_received' => 2 } }))['subscores']['report']
      expect(sub['reason_codes'].map { |r| r['code'] }).to include('reports_received_24h')
    end
  end

  describe 'follow_import guardrails' do
    it 'does NOT fire on import count/size alone (known relationships, low unresolved)' do
      sub = evaluate(metrics(follow_import: { 'batch_count' => 5, 'target_total' => 3000, 'unresolved_target_ratio' => 0.05, 'prior_relationship_known_targets' => 2500 }))['subscores']['follow_import']

      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
    end

    it 'fires on the external-list shape (large + high unresolved + no known relationships)' do
      sub = evaluate(metrics(follow_import: { 'batch_count' => 4, 'target_total' => 3000, 'unresolved_target_ratio' => 0.95, 'prior_relationship_known_targets' => 0 }))['subscores']['follow_import']

      codes = sub['reason_codes'].map { |r| r['code'] }
      expect(codes).to include('large_unknown_follow_import', 'high_unresolved_target_ratio', 'no_known_relationships_in_large_import')
      expect(sub['score']).to eq 1.0 # 0.5 + 0.3 + 0.2, capped
    end
  end

  describe 'repeat_behavior' do
    it 'fires on continuation after the first negative signal' do
      sub = evaluate(metrics(windows: { '24h' => { 'new_targets_after_first_negative_signal' => 100, 'follows_after_first_negative_signal' => 80 } }))['subscores']['repeat_behavior']

      expect(sub['reason_codes'].map { |r| r['code'] }).to include('continuation_after_rejection', 'follows_after_rejection')
      expect(sub['score']).to eq 1.0
    end
  end

  describe 'score capping' do
    it 'caps a sub-score at 1.0 when several signals fire' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 250, 'contacts_total' => 600 }, '7d' => { 'unique_targets' => 600 } }))['subscores']['contact_volume']

      expect(sub['score']).to eq 1.0
      expect(sub['reason_codes'].size).to eq 3
    end
  end

  describe 'read-only over a real account' do
    it 'evaluates an account with no ledger history to all-zero without writing' do
      account = Fabricate(:account, username: 'risk_fresh')

      result = nil
      expect { result = described_class.new.call(account, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['subject_id']).to be_nil
      result['subscores'].each_value { |sub| expect(sub['score']).to eq 0.0 }
    end
  end
end
