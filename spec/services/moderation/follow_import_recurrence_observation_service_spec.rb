# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::FollowImportRecurrenceObservationService do
  subject(:service) { described_class.new }

  let(:now) { Time.utc(2026, 9, 21, 16, 0, 0) }
  let(:lookback) { 7.days }
  let(:max_gap) { 30.minutes }
  let(:importer) { Fabricate(:moderation_subject) }
  let(:historical) { Fabricate(:moderation_subject) }
  let(:target_a) { Fabricate(:moderation_subject) }
  let(:target_b) { Fabricate(:moderation_subject) }
  let(:target_c) { Fabricate(:moderation_subject) }

  def create_batch(subject, targets:, at:, unresolved: 0)
    batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: at,
      mode: :merge,
      target_count: targets.size + unresolved,
      resolved_target_count: targets.uniq.size,
      unresolved_target_count: unresolved
    )
    targets.each_with_index do |target, position|
      batch.targets.create!(target_subject: target, position: position)
    end
    unresolved.times do |index|
      batch.targets.create!(target_key_hash: "unresolved-#{batch.id}-#{index}", position: targets.size + index)
    end
    batch
  end

  def create_moderated_snapshot(subject, linked_ids:, **attrs)
    reported_count = attrs[:reported_count]
    snapshot = Fabricate(
      :moderation_evidence_snapshot,
      subject: subject,
      summary: reported_count.nil? && attrs[:omit_reported] ? {} : { 'linked_negative_target_count' => reported_count || linked_ids.size },
      fingerprint: { 'linked_negative_target_subject_ids' => linked_ids }
    )
    Fabricate(
      :moderation_action,
      subject: subject,
      evidence_snapshot: snapshot,
      action_type: attrs.fetch(:action_type, :suspend),
      performed_at: attrs.fetch(:performed_at, now - 1.day)
    )
    snapshot
  end

  def observe(target = importer, **attrs)
    described_class.new(campaign_service: attrs[:campaign_service] || Moderation::FollowImportCampaignNegativeTargetOverlapService.new).call(
      target,
      now: attrs.fetch(:now, now),
      lookback: attrs.fetch(:lookback, lookback),
      max_gap: attrs.fetch(:max_gap, max_gap)
    )
  end

  def ledger_counts
    [
      ModerationSubject.count,
      ModerationInteractionEvent.count,
      ModerationRejectionEvent.count,
      ModerationAction.count,
      ModerationEvidenceSnapshot.count,
      FollowImportBatch.count,
      FollowImportTarget.count,
      Follow.count,
      Block.count,
      Mute.count,
    ]
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

  describe 'subject resolution' do
    it 'resolves a ModerationSubject directly and stays read-only' do
      create_batch(importer, targets: [target_a], at: now - 1.hour)
      result = nil

      expect { result = observe(importer) }.to_not(change { ledger_counts })
      expect(result['available']).to be true
      expect(result['subject_id']).to eq importer.id
      expect(result['reason']).to be_nil
    end

    it 'uses an existing subject for an Account without creating one' do
      account = importer.account
      create_batch(importer, targets: [target_a], at: now - 1.hour)
      result = nil

      expect { result = observe(account) }.to_not change(ModerationSubject, :count)
      expect(result['available']).to be true
      expect(result['subject_id']).to eq importer.id
    end

    it 'returns a stable unavailable shape when no moderation subject exists' do
      fresh = Fabricate(:account, username: 'recurrence_never_seen')
      result = nil

      expect { result = observe(fresh) }.to_not change(ModerationSubject, :count)
      expect(result['available']).to be false
      expect(result['reason']).to eq 'no_moderation_subject'
      expect(result['subject_id']).to be_nil
      expect(result['batch_count']).to eq 0
      expect(result['campaign_count']).to eq 0
      expect(result['latest_campaign']).to be_nil
      expect(result['lookback_seconds']).to eq lookback.to_f
      expect(result['max_gap_seconds']).to eq max_gap.to_f
      expect(result['imported_at_from']).to eq now - lookback
      expect(result['imported_at_to']).to eq now
    end
  end

  describe 'batch cutoff' do
    it 'returns a stable empty observation when no batches fall in lookback' do
      result = observe(importer)

      expect(result['available']).to be false
      expect(result['reason']).to eq 'no_follow_import_batches_in_lookback'
      expect(result['subject_id']).to eq importer.id
      expect(result['batch_count']).to eq 0
      expect(result['campaign_count']).to eq 0
      expect(result['latest_campaign']).to be_nil
    end

    it 'includes only batches with imported_at <= now' do
      visible = create_batch(importer, targets: [target_a], at: now)
      create_batch(importer, targets: [target_b], at: now + 1.minute)

      result = observe(importer)
      campaign = result['latest_campaign']

      expect(result['available']).to be true
      expect(result['batch_count']).to eq 1
      expect(campaign['campaign_key']).to eq "#{importer.id}:#{visible.id}"
      expect(campaign['ended_at']).to eq now
      expect(campaign['comparable_unique_target_count']).to eq 1
      expect(FollowImportBatch.where(subject_id: importer.id).count).to eq 2
    end

    it 'excludes batches older than lookback' do
      create_batch(importer, targets: [target_a, target_b], at: now - lookback - 1.second)
      recent = create_batch(importer, targets: [target_c], at: now - 1.hour)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id])

      result = observe(importer)
      campaign = result['latest_campaign']
      match = campaign.dig('cross_subject', 'best_match')

      expect(result['batch_count']).to eq 1
      expect(campaign['ended_at']).to eq recent.imported_at
      expect(campaign['comparable_unique_target_count']).to eq 1
      expect(match['overlap_count']).to eq 1
    end
  end

  describe 'latest campaign selection' do
    it 'selects the latest campaign deterministically by ended_at then started_at' do
      create_batch(importer, targets: [target_a], at: now - 2.hours)
      later = create_batch(importer, targets: [target_b], at: now - 10.minutes)

      result = observe(importer)
      campaign = result['latest_campaign']

      expect(result['campaign_count']).to eq 2
      expect(campaign['started_at']).to eq later.imported_at
      expect(campaign['ended_at']).to eq later.imported_at
      expect(campaign['campaign_key']).to eq "#{importer.id}:#{later.id}"
      expect(campaign['seconds_since_last_batch']).to eq 10.minutes.to_f
    end

    it 'returns a defensive unavailable shape when batches exist but no campaign row is produced' do
      create_batch(importer, targets: [target_a], at: now - 1.hour)
      fake = instance_double(Moderation::FollowImportCampaignNegativeTargetOverlapService)
      allow(fake).to receive(:call).and_return('campaigns' => [], 'campaign_count' => 0)

      result = observe(importer, campaign_service: fake)

      expect(result['available']).to be false
      expect(result['reason']).to eq 'no_campaign_row'
      expect(result['batch_count']).to eq 1
      expect(result['campaign_count']).to eq 0
      expect(result['latest_campaign']).to be_nil
    end
  end

  describe 'composed campaign features' do
    it 'uses overlap values from the composed campaign service rather than duplicated math' do
      visible = create_batch(importer, targets: [target_a], at: now - 5.minutes)
      injected = {
        'campaign_index' => 0,
        'campaign_key' => "#{importer.id}:#{visible.id}",
        'started_at' => visible.imported_at,
        'ended_at' => visible.imported_at,
        'duration_seconds' => 0.0,
        'batch_count' => 4,
        'target_rows' => 99,
        'comparable_unique_target_count' => 42,
        'unresolved_or_unmapped_target_rows' => 7,
        'same_subject' => { 'matching_snapshot_count' => 0, 'best_match' => nil },
        'cross_subject' => {
          'matching_snapshot_count' => 1,
          'best_match' => {
            'snapshot_id' => 88,
            'historical_subject_id' => historical.id,
            'action_types' => ['suspend'],
            'latest_action_performed_at' => now - 2.days,
            'historical_fingerprint_complete' => true,
            'stored_linked_negative_target_count' => 355,
            'reported_linked_negative_target_count' => 355,
            'overlap_count' => 231,
            'current_target_overlap_ratio' => 0.8,
            'stored_negative_containment' => 0.650704,
            'jaccard' => 0.12,
            'linked_negative_target_subject_ids' => [target_a.id],
          },
        },
      }
      fake = instance_double(Moderation::FollowImportCampaignNegativeTargetOverlapService)
      expect(fake).to receive(:call) do |received, max_gap:, now:|
        expect(received.map(&:id)).to eq [visible.id]
        expect(max_gap).to eq 15.minutes
        expect(now).to eq Time.utc(2026, 9, 21, 16, 0, 0)
        { 'campaigns' => [injected], 'campaign_count' => 1 }
      end

      result = observe(importer, campaign_service: fake, max_gap: 15.minutes)
      match = result.dig('latest_campaign', 'cross_subject', 'best_match')

      expect(result['max_gap_seconds']).to eq 15.minutes.to_f
      expect(result['lookback_seconds']).to eq lookback.to_f
      expect(result.dig('latest_campaign', 'comparable_unique_target_count')).to eq 42
      expect(result.dig('latest_campaign', 'target_rows')).to eq 99
      expect(match['overlap_count']).to eq 231
      expect(match['stored_negative_containment']).to eq 0.650704
      expect(match).to_not have_key('linked_negative_target_subject_ids')
    end

    it 'keeps complete, incomplete, and unknown fingerprint state, and same/cross blocks, separate' do
      create_batch(importer, targets: [target_a, target_b], at: now - 20.minutes)
      create_moderated_snapshot(importer, linked_ids: [target_a.id], reported_count: 1, performed_at: now - 2.days)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id], reported_count: 8, performed_at: now - 1.day)

      result = observe(importer)
      campaign = result['latest_campaign']

      expect(campaign['same_subject']['matching_snapshot_count']).to eq 1
      expect(campaign.dig('same_subject', 'best_match', 'historical_fingerprint_complete')).to be true
      expect(campaign.dig('cross_subject', 'best_match', 'historical_fingerprint_complete')).to be false
      expect(campaign['same_subject']['best_match']['historical_subject_id']).to eq importer.id
      expect(campaign['cross_subject']['best_match']['historical_subject_id']).to eq historical.id

      unknown_importer = Fabricate(:moderation_subject)
      unknown_historical = Fabricate(:moderation_subject)
      create_batch(unknown_importer, targets: [target_a], at: now - 20.minutes)
      create_moderated_snapshot(unknown_historical, linked_ids: [target_a.id], omit_reported: true, performed_at: now - 1.day)

      unknown_result = observe(unknown_importer)
      expect(unknown_result.dig('latest_campaign', 'cross_subject', 'best_match', 'historical_fingerprint_complete')).to be_nil
    end

    it 'does not leak target subject ID arrays' do
      create_batch(importer, targets: [target_a, target_b], at: now - 5.minutes)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id])

      result = observe(importer)
      keys = collect_keys(result)

      expect(keys).to_not include(
        'linked_negative_target_subject_ids',
        'negative_target_subject_ids',
        'target_subject_ids',
        'comparable_ids',
        'overlap_ids',
        'batch_ids'
      )
      expect(result.dig('latest_campaign', 'cross_subject', 'best_match').keys).to match_array(
        Moderation::FollowImportCampaignNegativeTargetOverlapService::BEST_MATCH_KEYS
      )
    end
  end

  describe 'production-shaped regression' do
    it 'reports factual cross-subject containment for a recent multi-batch campaign without scoring' do
      create_batch(importer, targets: [target_a, target_b], at: now - 12.minutes)
      create_batch(importer, targets: [target_b, target_c], at: now - 10.minutes)
      snapshot = create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id, Fabricate(:moderation_subject).id])
      result = nil

      expect { result = observe(importer) }.to_not(change { ledger_counts })

      campaign = result['latest_campaign']
      match = campaign.dig('cross_subject', 'best_match')

      expect(result['available']).to be true
      expect(result['campaign_count']).to eq 1
      expect(campaign['batch_count']).to eq 2
      expect(campaign['comparable_unique_target_count']).to eq 3
      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['historical_subject_id']).to eq historical.id
      expect(match['overlap_count']).to eq 3
      expect(match['stored_negative_containment']).to eq 0.75
      expect(result).to_not have_key('score')
      expect(result).to_not have_key('recommendation')
      expect(result).to_not have_key('proposed_friction')
      expect(campaign).to_not have_key('outcome')
    end
  end
end
# rubocop:enable Metrics/BlockLength
