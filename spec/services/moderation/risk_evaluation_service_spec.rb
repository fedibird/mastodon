# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::RiskEvaluationService do
  let(:now) { Time.now.utc }

  WINDOW_DEFAULTS = {
    'contacts_total' => 0, 'unique_targets' => 0, 'follows' => 0, 'unique_follow_targets' => 0,
    'reports_received' => 0, 'unique_negative_responders' => 0, 'linked_negative_responders' => 0,
    'qualified_negative_events' => 0, 'qualified_unique_negative_responders' => 0,
    'negative_response_rate' => 0.0, 'qualified_negative_response_rate' => 0.0,
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
    it 'is versioned/auditable, keyed by subject, and carries only sub-scores (no action/decision)' do
      result = evaluate(metrics)

      expect(result['policy_version']).to eq described_class::POLICY_VERSION
      expect(result['params_digest']).to start_with('sha256:')
      expect(result['subject_id']).to eq 1
      expect(result['subscores'].keys).to contain_exactly(
        'contact_volume', 'velocity', 'rejection', 'report', 'follow_import', 'repeat_behavior'
      )
      # Evaluation must not decide or recommend anything, and must not emit a single score.
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
    it 'fires with an explaining reason code carrying value + threshold + weight + window' do
      result = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 250 } }))
      sub = result['subscores']['contact_volume']

      expect(sub['score']).to eq 0.5
      expect(sub['reason_codes']).to include(
        a_hash_including('code' => 'high_unique_targets_24h', 'value' => 250, 'threshold' => 200, 'weight' => 0.5, 'window' => '24h')
      )
    end

    it 'lets a sub-score be reconstructed from its reason codes' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 250, 'contacts_total' => 600 } }))['subscores']['contact_volume']

      reconstructed = [sub['reason_codes'].sum { |r| r['weight'] }, 1.0].min
      expect(sub['score']).to eq reconstructed
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
    it 'does NOT fire for a single qualified independent rejector' do
      sub = evaluate(metrics(windows: { '24h' => { 'qualified_unique_negative_responders' => 1, 'linked_negative_responders' => 1 } }))['subscores']['rejection']

      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
    end

    it 'does NOT fire on raw unique responders when the qualified cohort is empty' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_negative_responders' => 8, 'linked_negative_responders' => 0, 'qualified_unique_negative_responders' => 0 } }))['subscores']['rejection']

      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
    end

    it 'does not double-count linked responders as a second rejection signal' do
      sub = evaluate(metrics(windows: { '24h' => { 'qualified_unique_negative_responders' => 6, 'linked_negative_responders' => 6 } }))['subscores']['rejection']

      expect(sub['reason_codes'].map { |r| r['code'] }).to eq %w(multiple_qualified_independent_rejectors)
      expect(sub['score']).to eq 0.5
    end

    it 'fires only once multiple qualified independent responders are present' do
      sub = evaluate(metrics(windows: { '24h' => { 'qualified_unique_negative_responders' => 6 } }))['subscores']['rejection']

      expect(sub['reason_codes'].map { |r| r['code'] }).to include('multiple_qualified_independent_rejectors')
      expect(sub['reason_codes'].map { |r| r['code'] }).to_not include('multiple_independent_rejectors', 'linked_independent_rejectors')
      expect(sub['score']).to be > 0.0
    end

    it 'ignores qualified_negative_response_rate on a tiny contact sample' do
      # rate is high but only 3 unique targets -> below min_unique_targets guard.
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 3, 'qualified_negative_response_rate' => 0.9 } }))['subscores']['rejection']

      expect(sub['reason_codes']).to be_empty
    end

    it 'counts an elevated qualified rate once the sample is large enough and records the sample condition' do
      sub = evaluate(metrics(windows: { '24h' => { 'unique_targets' => 50, 'qualified_negative_response_rate' => 0.3 } }))['subscores']['rejection']

      expect(sub['reason_codes']).to include(
        a_hash_including(
          'code' => 'elevated_qualified_negative_response_rate', 'value' => 0.3, 'threshold' => 0.2, 'weight' => 0.3, 'window' => '24h',
          'observed_unique_targets' => 50, 'min_unique_targets' => 10
        )
      )
    end
  end

  describe 'report' do
    it 'fires on reports received' do
      sub = evaluate(metrics(windows: { '24h' => { 'reports_received' => 2 } }))['subscores']['report']
      expect(sub['reason_codes'].map { |r| r['code'] }).to include('reports_received_24h')
    end
  end

  describe 'follow_import is deferred' do
    it 'always scores 0 and adds no reason codes, regardless of import shape' do
      # Even the "external-list-looking" shape must not score, because unresolved
      # != unknown-relationship. Deferred until relationship-aware features exist.
      sub = evaluate(metrics(follow_import: { 'batch_count' => 4, 'target_total' => 3000, 'unresolved_target_ratio' => 0.95, 'prior_relationship_known_targets' => 0 }))['subscores']['follow_import']

      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
      expect(sub['deferred']).to be true
      expect(sub['deferred_reason']).to eq 'relationship_aware_features_not_yet_available'
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

  describe 'policy versioning and params auditability' do
    let(:custom_params) do
      params = Marshal.load(Marshal.dump(described_class::DEFAULT_PARAMS))
      params['contact_volume']['unique_targets_24h']['threshold'] = 10
      params
    end

    def evaluate_with(params:, policy_version: nil)
      fake = instance_double(Moderation::BehavioralMetricsService, call: metrics)
      described_class.new(metrics_service: fake, params: params, policy_version: policy_version).call(ModerationSubject.new.tap { |s| s.id = 1 }, now: now)
    end

    it 'reports the default policy version and a stable digest for default params' do
      a = evaluate_with(params: described_class::DEFAULT_PARAMS)
      b = evaluate_with(params: described_class::DEFAULT_PARAMS)

      expect(a['policy_version']).to eq described_class::POLICY_VERSION
      expect(a['params_digest']).to eq b['params_digest']
    end

    it 'does not let custom params masquerade as the default policy version' do
      result = evaluate_with(params: custom_params)

      expect(result['policy_version']).to eq 'custom'
      expect(result['params_digest']).to_not eq evaluate_with(params: described_class::DEFAULT_PARAMS)['params_digest']
    end

    it 'honors an explicit policy_version for custom params' do
      result = evaluate_with(params: custom_params, policy_version: 'risk-eval-experiment-A')
      expect(result['policy_version']).to eq 'risk-eval-experiment-A'
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

  describe 'qualified rejection cohort on the ledger' do
    let(:actor) { Fabricate(:account, username: 'risk_qual_actor') }

    def record_interaction(target, type, at, key)
      Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: type, occurred_at: at, source_event_key: key)
    end

    def record_rejection(rejector, type, at, key)
      Moderation::EventRecorder.record_rejection(rejector: rejector, rejected: actor, event_type: type, occurred_at: at, source_event_key: key)
    end

    def rejection_sub
      described_class.new.call(actor, now: now).dig('subscores', 'rejection')
    end

    it 'does not raise the rejection subscore for five or more raw unqualified Follow Rejects' do
      5.times do |i|
        stranger = Fabricate(:account, username: "risk_raw_#{i}")
        record_rejection(stranger, :follow_reject, now - (10 + i).minutes, "risk-raw-#{i}")
      end

      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')
      sub = rejection_sub

      expect(metrics['rejections_received_total']).to eq 5
      expect(metrics['unique_negative_responders']).to eq 5
      expect(metrics['qualified_unique_negative_responders']).to eq 0
      expect(sub['score']).to eq 0.0
      expect(sub['reason_codes']).to be_empty
    end

    it 'does not fire multiple_*rejectors for synthetic/unlinked Rejects from several servers' do
      6.times do |i|
        remote = Fabricate(:account, username: "risk_syn_#{i}", domain: "misskey-#{i}.example")
        record_rejection(remote, :follow_reject, now - (5 + i).minutes, "risk-syn-#{i}")
      end

      sub = rejection_sub
      codes = sub['reason_codes'].map { |r| r['code'] }

      expect(sub['score']).to eq 0.0
      expect(codes.grep(/rejectors/)).to be_empty
      expect(codes).to_not include('multiple_independent_rejectors', 'multiple_qualified_independent_rejectors')
    end

    it 'fires multiple_qualified_independent_rejectors once the qualified cohort reaches the threshold' do
      5.times do |i|
        peer = Fabricate(:account, username: "risk_qual_#{i}")
        record_interaction(peer, :follow, now - (60 - i).minutes, "risk-qi-#{i}")
        record_rejection(peer, :follow_reject, now - (50 - i).minutes, "risk-qr-#{i}")
      end

      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')
      sub = rejection_sub

      expect(metrics['qualified_unique_negative_responders']).to eq 5
      expect(sub['reason_codes'].map { |r| r['code'] }).to include('multiple_qualified_independent_rejectors')
      expect(sub['reason_codes']).to include(a_hash_including('code' => 'multiple_qualified_independent_rejectors', 'value' => 5, 'threshold' => 5))
    end

    it 'counts one unique qualified responder when the same account returns several qualified negatives' do
      peer = Fabricate(:account, username: 'risk_repeat_peer')
      record_interaction(peer, :follow, now - 50.minutes, 'risk-rep-i1')
      record_rejection(peer, :block, now - 40.minutes, 'risk-rep-r1')
      record_interaction(peer, :mention, now - 30.minutes, 'risk-rep-i2')
      record_rejection(peer, :mute, now - 20.minutes, 'risk-rep-r2')

      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')

      expect(metrics['qualified_negative_events']).to eq 2
      expect(metrics['qualified_unique_negative_responders']).to eq 1
      expect(metrics['unique_negative_responders']).to eq 1
      expect(rejection_sub['reason_codes']).to be_empty
    end

    it 'keeps raw metrics and first-qualified / repeat_behavior semantics from diagnostics' do
      stranger = Fabricate(:account, username: 'risk_early_raw')
      later = Fabricate(:account, username: 'risk_later_qual')
      fresh = Fabricate(:account, username: 'risk_after_qual')

      record_rejection(stranger, :follow_reject, now - 90.minutes, 'risk-early-raw')
      record_interaction(later, :follow, now - 40.minutes, 'risk-later-i')
      record_rejection(later, :block, now - 30.minutes, 'risk-later-r')
      record_interaction(fresh, :follow, now - 10.minutes, 'risk-after')

      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')
      evaluation = described_class.new.call(actor, now: now)
      diagnostics = Moderation::SubjectDiagnosticsService.new.call(actor, now: now)

      expect(metrics['rejections_received_total']).to eq 2
      expect(metrics['unique_negative_responders']).to eq 2
      expect(metrics['rejections_by_type']['follow_reject']).to eq 1
      expect(metrics['first_negative_signal_at']).to eq((now - 30.minutes).iso8601)
      expect(metrics['new_targets_after_first_negative_signal']).to eq 1
      expect(diagnostics.dig('continuation', 'first_qualified_negative_at')).to eq metrics['first_negative_signal_at']
      expect(evaluation.dig('subscores', 'repeat_behavior', 'score')).to eq 0.0
    end

    it 'aligns diagnostics qualified counts with the values risk evaluation reads' do
      5.times do |i|
        peer = Fabricate(:account, username: "risk_align_#{i}")
        record_interaction(peer, :follow, now - (60 - i).minutes, "risk-ai-#{i}")
        record_rejection(peer, :follow_reject, now - (50 - i).minutes, "risk-ar-#{i}")
      end

      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')
      diagnostics = Moderation::SubjectDiagnosticsService.new.call(actor, now: now)
      evaluation = diagnostics['evaluation']
      reason = evaluation.dig('subscores', 'rejection', 'reason_codes').find { |r| r['code'] == 'multiple_qualified_independent_rejectors' }

      expect(diagnostics.dig('negative_signals', '24h', 'qualified_events')).to eq metrics['qualified_negative_events']
      expect(diagnostics.dig('negative_signals', '24h', 'qualified_unique_responders')).to eq metrics['qualified_unique_negative_responders']
      expect(diagnostics.dig('negative_signals', '24h', 'qualified_response_rate')).to eq metrics['qualified_negative_response_rate']
      expect(reason['value']).to eq metrics['qualified_unique_negative_responders']
      expect(reason['value']).to eq diagnostics.dig('negative_signals', '24h', 'qualified_unique_responders')
    end

    it 'lets a Misskey-style synthetic Follow Reject stay visible as raw without raising rejection risk' do
      remote = Fabricate(:account, username: 'risk_misskey', domain: 'misskey.example')
      record_rejection(remote, :follow_reject, now - 15.minutes, 'risk-misskey-raw')

      diagnostics = Moderation::SubjectDiagnosticsService.new.call(actor, now: now)
      evaluation = described_class.new.call(actor, now: now)

      expect(diagnostics.dig('negative_signals', '24h', 'raw_events')).to eq 1
      expect(diagnostics.dig('negative_signals', '24h', 'qualified_events')).to eq 0
      expect(evaluation.dig('subscores', 'rejection', 'score')).to eq 0.0
      expect(evaluation.dig('subscores', 'rejection', 'reason_codes')).to be_empty
    end
  end
end
