# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::SubjectDiagnosticsService do
  subject(:service) { described_class.new }

  let(:now)   { Time.now.utc }
  let(:actor) { Fabricate(:account, username: 'diag_actor') }
  let(:b)     { Fabricate(:account, username: 'diag_b') }
  let(:c)     { Fabricate(:account, username: 'diag_c') }
  let(:d)     { Fabricate(:account, username: 'diag_d') }

  def record_interaction(target, type, at, key)
    Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: type, occurred_at: at, source_event_key: key)
  end

  def record_rejection(rejector, type, at, key)
    Moderation::EventRecorder.record_rejection(rejector: rejector, rejected: actor, event_type: type, occurred_at: at, source_event_key: key)
  end

  def mutation_counts
    {
      subjects: ModerationSubject.count,
      interactions: ModerationInteractionEvent.count,
      rejections: ModerationRejectionEvent.count,
      actions: ModerationAction.count,
      snapshots: ModerationEvidenceSnapshot.count,
      follows: Follow.count,
      blocks: Block.count,
      mutes: Mute.count,
    }
  end

  def collect_keys(value, keys = [])
    case value
    when Hash
      value.each do |key, child|
        keys << key.to_s
        collect_keys(child, keys)
      end
    when Array
      value.each { |child| collect_keys(child, keys) }
    end
    keys
  end

  describe 'stable empty shape' do
    it 'returns the operator-facing keys with zeros when nothing was observed' do
      fresh = Fabricate(:account, username: 'diag_never_seen')
      result = nil

      expect { result = service.call(fresh, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['subject_id']).to be_nil
      expect(result['account_id']).to be_nil
      expect(result['generated_at']).to eq now.iso8601
      expect(result['contacts']).to eq(
        '1h' => { 'total' => 0, 'unique_targets' => 0 },
        '24h' => { 'total' => 0, 'unique_targets' => 0 },
        '7d' => { 'total' => 0, 'unique_targets' => 0 }
      )
      expect(result.dig('negative_signals', '24h')).to include(
        'raw_events' => 0,
        'qualified_events' => 0,
        'unqualified_events' => 0,
        'unique_responders' => 0,
        'linked_responders' => 0,
        'qualified_unique_responders' => 0,
        'qualified_response_rate' => 0.0,
        'qualification_rate' => 0.0,
        'link_rate' => 0.0
      )
      expect(result.dig('negative_signals', '24h', 'by_type').keys).to match_array(Moderation::BehavioralMetricsService::REJECTION_TYPES)
      expect(result['continuation']).to eq(
        'first_qualified_negative_at' => nil,
        'new_targets_after_first_negative_signal_24h' => 0,
        'follows_after_first_negative_signal_24h' => 0
      )
      expect(result['reports']).to eq('24h' => 0, '7d' => 0)
      expect(result['follow_import']).to include(
        'batch_count' => 0,
        'target_total' => 0,
        'resolved_target_count' => 0,
        'unresolved_target_count' => 0,
        'unresolved_target_ratio' => 0.0
      )
      expect(result.dig('follow_import', 'recurrence_observation')).to include(
        'available' => false,
        'reason' => 'no_moderation_subject',
        'latest_campaign' => nil,
        'batch_count' => 0
      )
      expect(result['observation_quality']['negative_qualification_rate']).to eq 0.0
      expect(result['observation_quality']['contact_link_rate']).to eq 0.0
      expect(result['observation_quality']['notes']).to include(
        'absence of observed negatives is not evidence of absence',
        'remote negative signals may be incompletely observed',
        'cross-subject linked-negative overlap is behavioral recurrence evidence, not identity proof',
        'max_gap is a grouping heuristic, not a policy threshold'
      )
      expect(result['observation_quality']).to_not have_key('confidence_score')
      expect(result['evaluation']).to include('subscores', 'policy_version')
      expect(result['follow_gate']).to include('proposed_friction', 'matched_rules', 'shadow')
    end
  end

  describe 'raw vs qualified negatives' do
    let(:stranger) { Fabricate(:account, username: 'diag_stranger') }

    before do
      record_interaction(b, :follow, now - 50.minutes, 'diag-i-b')
      record_rejection(b, :follow_reject, now - 40.minutes, 'diag-r-b')
      record_rejection(stranger, :follow_reject, now - 30.minutes, 'diag-r-unlinked')
      record_rejection(c, :block, now - 20.minutes, 'diag-r-c-raw-block')
    end

    it 'counts raw and qualified negatives separately and does not treat an unqualified Follow Reject as qualified' do
      result = service.call(actor, now: now)
      signals = result.dig('negative_signals', '24h')

      expect(signals['raw_events']).to eq 3
      expect(signals['qualified_events']).to eq 1
      expect(signals['unqualified_events']).to eq 2
      expect(signals.dig('by_type', 'follow_reject')).to eq('raw' => 2, 'qualified' => 1, 'unqualified' => 1)
      expect(signals.dig('by_type', 'block')).to eq('raw' => 1, 'qualified' => 0, 'unqualified' => 1)
      expect(signals['qualification_rate']).to be_within(1e-9).of(1.0 / 3)
    end

    it 'treats an outbound-correlated Follow Reject as a qualified negative' do
      result = service.call(actor, now: now)

      expect(result.dig('negative_signals', '24h', 'by_type', 'follow_reject', 'qualified')).to eq 1
      expect(result.dig('continuation', 'first_qualified_negative_at')).to eq((now - 40.minutes).iso8601)
    end
  end

  describe 'Misskey-style synthetic Follow Reject' do
    let(:remote) { Fabricate(:account, username: 'diag_misskey', domain: 'misskey.example') }

    before do
      # Raw follow_reject with no outbound Follow correlation. EventRecorder
      # leaves preceding_interaction_event nil — the same unlinked shape used
      # by BehavioralMetricsService for protocol-level / synthetic Rejects.
      record_rejection(remote, :follow_reject, now - 80.minutes, 'diag-misskey-raw')
      record_interaction(b, :follow, now - 50.minutes, 'diag-misskey-follow-b')
      record_interaction(c, :follow, now - 20.minutes, 'diag-misskey-follow-c')
    end

    it 'is visible as raw, excluded from qualified, and does not become the continuation anchor' do
      result = service.call(actor, now: now)
      signals = result.dig('negative_signals', '24h')

      expect(signals['raw_events']).to eq 1
      expect(signals['qualified_events']).to eq 0
      expect(signals.dig('by_type', 'follow_reject', 'raw')).to eq 1
      expect(signals.dig('by_type', 'follow_reject', 'qualified')).to eq 0
      expect(result.dig('continuation', 'first_qualified_negative_at')).to be_nil
      expect(result.dig('continuation', 'new_targets_after_first_negative_signal_24h')).to eq 0
      expect(result.dig('continuation', 'follows_after_first_negative_signal_24h')).to eq 0
      expect(result.dig('evaluation', 'subscores', 'repeat_behavior', 'score')).to eq 0.0
      expect(result.dig('evaluation', 'subscores', 'rejection', 'score')).to eq 0.0
      expect(result.dig('negative_signals', '24h', 'qualified_unique_responders')).to eq 0
    end
  end

  describe 'continuation anchor' do
    let(:stranger) { Fabricate(:account, username: 'diag_early_raw') }

    before do
      record_rejection(stranger, :follow_reject, now - 90.minutes, 'diag-early-raw')
      record_interaction(b, :follow, now - 70.minutes, 'diag-after-raw-b')
      record_interaction(c, :follow, now - 60.minutes, 'diag-after-raw-c')
      record_interaction(d, :follow, now - 40.minutes, 'diag-qual-i')
      record_rejection(d, :block, now - 30.minutes, 'diag-qual-r')
      record_interaction(Fabricate(:account, username: 'diag_after_qual'), :follow, now - 10.minutes, 'diag-after-qual')
    end

    it 'anchors continuation on the first qualified negative, not an earlier raw row' do
      result = service.call(actor, now: now)
      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')

      expect(result.dig('continuation', 'first_qualified_negative_at')).to eq((now - 30.minutes).iso8601)
      expect(result.dig('continuation', 'first_qualified_negative_at')).to eq metrics['first_negative_signal_at']
      expect(result.dig('continuation', 'new_targets_after_first_negative_signal_24h')).to eq 1
      expect(result.dig('continuation', 'follows_after_first_negative_signal_24h')).to eq 1
      expect(result.dig('continuation', 'new_targets_after_first_negative_signal_24h')).to eq metrics['new_targets_after_first_negative_signal']
    end
  end

  describe 'alignment with existing metrics and composed services' do
    before do
      record_interaction(b, :follow, now - 120.minutes, 'diag-align-b')
      record_interaction(c, :follow, now - 50.minutes, 'diag-align-c')
      record_rejection(b, :block, now - 118.minutes, 'diag-align-rb')
      record_rejection(c, :follow_reject, now - 48.minutes, 'diag-align-rc')
    end

    it 'uses the same unique/linked responder counts as BehavioralMetricsService' do
      result = service.call(actor, now: now)
      metrics = Moderation::BehavioralMetricsService.new.call(actor, now: now).dig('windows', '24h')
      signals = result.dig('negative_signals', '24h')

      expect(signals['unique_responders']).to eq metrics['unique_negative_responders']
      expect(signals['linked_responders']).to eq metrics['linked_negative_responders']
      expect(signals['qualified_unique_responders']).to eq metrics['qualified_unique_negative_responders']
      expect(signals['qualified_response_rate']).to eq metrics['qualified_negative_response_rate']
      expect(signals['qualified_events']).to eq metrics['qualified_negative_events']
      expect(result.dig('contacts', '24h', 'total')).to eq metrics['contacts_total']
      expect(result.dig('contacts', '24h', 'unique_targets')).to eq metrics['unique_targets']
    end

    it 'embeds the RiskEvaluationService output without reimplementing thresholds' do
      result = service.call(actor, now: now)
      evaluation = Moderation::RiskEvaluationService.new.call(actor, now: now)

      expect(result['evaluation']).to eq evaluation
      expect(result['evaluation']['subscores'].keys).to include(
        'contact_volume', 'velocity', 'rejection', 'report', 'follow_import', 'repeat_behavior'
      )
    end

    it 'embeds AdaptiveFollowGateDecisionService proposed_friction and matched_rules' do
      result = service.call(actor, now: now)
      decision = Moderation::AdaptiveFollowGateDecisionService.new.call(actor, now: now)

      expect(result['follow_gate']['proposed_friction']).to eq decision['proposed_friction']
      expect(result['follow_gate']['matched_rules']).to eq decision['matched_rules']
      expect(result['follow_gate']['shadow']).to be true
      expect(result['follow_gate']['evaluation']).to eq result['evaluation']
    end

    it 'forwards follow-attempt context to the decision service unchanged' do
      context = {
        'mechanism' => 'follow_import',
        'target_locality' => 'remote',
        'target_locked' => false,
        'relationship_context' => 'unknown',
      }
      seen = nil
      gate = instance_double(Moderation::AdaptiveFollowGateDecisionService)
      allow(gate).to receive(:call) do |target, **kwargs|
        seen = { target: target, context: kwargs[:context], now: kwargs[:now] }
        { 'proposed_friction' => 'delay', 'matched_rules' => [{ 'rule' => 'elevated_rejection_non_local_target' }], 'shadow' => true }
      end

      result = described_class.new(gate: gate).call(actor, context: context, now: now)

      expect(seen[:target]).to eq actor
      expect(seen[:context]).to eq context
      expect(seen[:now]).to eq now
      expect(result.dig('follow_gate', 'proposed_friction')).to eq 'delay'
      expect(result.dig('follow_gate', 'matched_rules')).to eq([{ 'rule' => 'elevated_rejection_non_local_target' }])
    end

    it 'also echoes context through the real decision service when none is injected' do
      context = {
        'mechanism' => 'api',
        'target_locality' => 'local',
        'target_locked' => true,
        'relationship_context' => 'following',
      }
      result = service.call(actor, context: context, now: now)

      expect(result.dig('follow_gate', 'context')).to include(
        'mechanism' => 'api',
        'target_locality' => 'local',
        'target_locked' => true,
        'relationship_context' => 'following'
      )
    end
  end

  describe 'read-only and privacy guarantees' do
    before do
      record_interaction(b, :follow, now - 15.minutes, 'diag-ro-i')
      record_rejection(b, :block, now - 10.minutes, 'diag-ro-r')
    end

    it 'does not write ledger, enforcement, or relationship rows' do
      before_counts = mutation_counts
      result = service.call(actor, now: now)

      expect(mutation_counts).to eq before_counts
      expect(result['subject_id']).to eq ModerationSubject.find_by(account_id: actor.id).id
    end

    it 'does not emit post, DM, profile, report, or ActivityPub payload bodies' do
      result = service.call(actor, now: now)
      keys = collect_keys(result)

      expect(keys).to_not include(
        'content', 'text', 'spoiler_text', 'comment', 'payload', 'activity',
        'acct', 'note', 'display_name', 'status_ids', 'target_accts'
      )
    end
  end

  describe 'observation-quality rates' do
    it 'does not divide by zero when there are no negatives or responders' do
      record_interaction(b, :follow, now - 5.minutes, 'diag-zero-i')
      result = service.call(actor, now: now)

      expect(result.dig('negative_signals', '24h', 'qualification_rate')).to eq 0.0
      expect(result.dig('negative_signals', '24h', 'link_rate')).to eq 0.0
      expect(result.dig('observation_quality', 'negative_qualification_rate')).to eq 0.0
      expect(result.dig('observation_quality', 'contact_link_rate')).to eq 0.0
      expect(result.dig('observation_quality', 'complete_for_remote_subjects')).to be false
    end
  end

  describe 'Follow Import recurrence observation' do
    def create_import_batch(subject, targets:, at:)
      batch = FollowImportBatch.create!(
        subject: subject,
        imported_at: at,
        mode: :merge,
        target_count: targets.size,
        resolved_target_count: targets.size,
        unresolved_target_count: 0
      )
      targets.each_with_index do |target, position|
        batch.targets.create!(target_subject: target, position: position)
      end
      batch
    end

    it 'embeds recurrence_observation under follow_import without changing evaluation or follow_gate' do
      record_interaction(b, :follow, now - 50.minutes, 'diag-recurrence-i')
      record_rejection(b, :block, now - 40.minutes, 'diag-recurrence-r')
      subject_row = ModerationSubject.find_by!(account_id: actor.id)
      target_a = Fabricate(:moderation_subject)
      target_b = Fabricate(:moderation_subject)
      historical = Fabricate(:moderation_subject)
      create_import_batch(subject_row, targets: [target_a, target_b], at: now - 12.minutes)
      create_import_batch(subject_row, targets: [target_b], at: now - 10.minutes)
      snapshot = Fabricate(
        :moderation_evidence_snapshot,
        subject: historical,
        summary: { 'linked_negative_target_count' => 4 },
        fingerprint: { 'linked_negative_target_subject_ids' => [target_a.id, target_b.id, Fabricate(:moderation_subject).id, Fabricate(:moderation_subject).id] }
      )
      Fabricate(:moderation_action, subject: historical, evidence_snapshot: snapshot, action_type: :suspend, performed_at: now - 1.day)

      result = nil
      expect { result = service.call(actor, now: now) }.to_not(change { mutation_counts })

      observation = result.dig('follow_import', 'recurrence_observation')
      match = observation.dig('latest_campaign', 'cross_subject', 'best_match')
      evaluation = Moderation::RiskEvaluationService.new.call(actor, now: now)
      decision = Moderation::AdaptiveFollowGateDecisionService.new.call(actor, now: now)

      expect(observation['available']).to be true
      expect(observation['subject_id']).to eq subject_row.id
      expect(observation['lookback_seconds']).to eq 7.days.to_f
      expect(observation['max_gap_seconds']).to eq 30.minutes.to_f
      expect(observation.dig('latest_campaign', 'batch_count')).to eq 2
      expect(match['historical_subject_id']).to eq historical.id
      expect(match['stored_negative_containment']).to eq 0.5
      expect(result['evaluation']).to eq evaluation
      expect(result['follow_gate']['proposed_friction']).to eq decision['proposed_friction']
      expect(result['follow_gate']['matched_rules']).to eq decision['matched_rules']
      expect(result['evaluation']['subscores']['follow_import']['score']).to eq 0.0
      expect(observation).to_not have_key('score')
      expect(collect_keys(observation)).to_not include(
        'linked_negative_target_subject_ids',
        'target_subject_ids',
        'comparable_ids'
      )
    end

    it 'uses an injected recurrence observer without touching evaluation output' do
      fake_observation = {
        'available' => true,
        'reason' => nil,
        'subject_id' => 1,
        'latest_campaign' => { 'campaign_key' => 'injected' },
      }
      observer = instance_double(Moderation::FollowImportRecurrenceObservationService)
      expect(observer).to receive(:call).with(actor, now: now).and_return(fake_observation)

      result = described_class.new(recurrence_observer: observer).call(actor, now: now)
      evaluation = Moderation::RiskEvaluationService.new.call(actor, now: now)

      expect(result.dig('follow_import', 'recurrence_observation')).to eq fake_observation
      expect(result['evaluation']).to eq evaluation
    end
  end

  describe 'Follow Reject observation' do
    it 'embeds the read-only decomposition beside the 24h block' do
      record_interaction(b, :follow, now - 20.minutes, 'diag-fr-i')
      record_rejection(b, :follow_reject, now - 19.minutes, 'diag-fr-r')

      result = service.call(actor, now: now)
      observation = Moderation::FollowRejectObservationService.new.call(actor, now: now)
      evaluation = Moderation::RiskEvaluationService.new.call(actor, now: now)
      decision = Moderation::AdaptiveFollowGateDecisionService.new.call(actor, now: now)

      expect(result.dig('negative_signals', 'follow_reject_observation')).to eq observation
      expect(result.dig('negative_signals', '24h').keys).to_not include('follow_reject_observation', 'latency_buckets')
      expect(result['evaluation']).to eq evaluation
      expect(result.dig('follow_gate', 'proposed_friction')).to eq decision['proposed_friction']
      expect(result.dig('follow_gate', 'matched_rules')).to eq decision['matched_rules']
    end

    it 'uses an injected follow reject observer without changing evaluation output' do
      observation = { 'windows' => {}, 'notes' => ['injected'] }
      observer = instance_double(Moderation::FollowRejectObservationService)
      expect(observer).to receive(:call).with(actor, now: now).and_return(observation)

      result = described_class.new(follow_reject_observer: observer).call(actor, now: now)
      evaluation = Moderation::RiskEvaluationService.new.call(actor, now: now)
      decision = Moderation::AdaptiveFollowGateDecisionService.new.call(actor, now: now)

      expect(result.dig('negative_signals', 'follow_reject_observation')).to eq observation
      expect(result.dig('negative_signals', '24h').keys).to_not include('follow_reject_observation')
      expect(result['evaluation']).to eq evaluation
      expect(result.dig('follow_gate', 'proposed_friction')).to eq decision['proposed_friction']
      expect(result.dig('follow_gate', 'matched_rules')).to eq decision['matched_rules']
    end
  end
end
# rubocop:enable Metrics/BlockLength
