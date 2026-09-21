# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::FollowImportCampaignNegativeTargetOverlapService do
  subject(:service) { described_class.new }

  let(:t0) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:now) { Time.utc(2026, 9, 21, 16, 0, 0) }
  let(:importer) { Fabricate(:moderation_subject) }
  let(:other_importer) { Fabricate(:moderation_subject) }
  let(:historical) { Fabricate(:moderation_subject) }
  let(:target_a) { Fabricate(:moderation_subject) }
  let(:target_b) { Fabricate(:moderation_subject) }
  let(:target_c) { Fabricate(:moderation_subject) }
  let(:target_d) { Fabricate(:moderation_subject) }
  let(:target_x) { Fabricate(:moderation_subject) }

  def create_batch(subject, targets: [], **attrs)
    unresolved = attrs.fetch(:unresolved, 0)
    batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: attrs.fetch(:at, t0),
      mode: attrs.fetch(:mode, :merge),
      migration_evidence: attrs.fetch(:migration_evidence, :none),
      import_id: attrs[:import_id],
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
      performed_at: attrs.fetch(:performed_at, t0 - 1.day)
    )
    snapshot
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

  describe 'campaign grouping' do
    it 'groups same-subject batches inside max_gap into one campaign' do
      first = create_batch(importer, targets: [target_a], at: t0, import_id: 11)
      second = create_batch(importer, targets: [target_b], at: t0 + 90.seconds, import_id: 12)
      third = create_batch(importer, targets: [target_c], at: t0 + 27.minutes, import_id: 13)

      result = service.call([third, first, second], now: now)

      expect(result['max_gap_seconds']).to eq 30.minutes.to_f
      expect(result['campaign_count']).to eq 1
      expect(result['subject_count']).to eq 1
      campaign = result['campaigns'].first
      expect(campaign['batch_count']).to eq 3
      expect(campaign['batch_ids']).to eq [first.id, second.id, third.id]
      expect(campaign['import_ids']).to eq [11, 12, 13]
      expect(campaign['started_at']).to eq t0
      expect(campaign['ended_at']).to eq t0 + 27.minutes
      expect(campaign['duration_seconds']).to eq 27.minutes.to_f
      expect(campaign['as_of']).to eq t0
    end

    it 'starts a new campaign when the consecutive gap exceeds max_gap' do
      first = create_batch(importer, targets: [target_a], at: t0)
      second = create_batch(importer, targets: [target_b], at: t0 + 31.minutes)

      result = service.call([first, second], max_gap: 30.minutes, now: now)

      expect(result['campaign_count']).to eq 2
      expect(result['campaigns'].map { |row| row['batch_ids'] }).to eq [[first.id], [second.id]]
    end

    it 'never groups different subjects' do
      first = create_batch(importer, targets: [target_a], at: t0)
      second = create_batch(other_importer, targets: [target_b], at: t0 + 1.second)

      result = service.call([first, second], now: now)

      expect(result['campaign_count']).to eq 2
      expect(result['subject_count']).to eq 2
      expect(result['campaigns'].map { |row| row['subject_id'] }).to contain_exactly(importer.id, other_importer.id)
    end

    it 'de-duplicates repeated input batch ids' do
      batch = create_batch(importer, targets: [target_a], at: t0)

      result = service.call([batch, batch], now: now)

      expect(result['campaign_count']).to eq 1
      expect(result['campaigns'].first['batch_count']).to eq 1
    end
  end

  describe 'campaign target union' do
    it 'unions unique resolved targets and counts unresolved rows without using them as identity' do
      first = create_batch(importer, targets: [target_a, target_b], unresolved: 1, at: t0)
      second = create_batch(importer, targets: [target_b, target_c], unresolved: 2, at: t0 + 1.minute)

      campaign = service.call([first, second], now: now)['campaigns'].first

      expect(campaign['target_rows']).to eq 7
      expect(campaign['comparable_unique_target_count']).to eq 3
      expect(campaign['unresolved_or_unmapped_target_rows']).to eq 3
    end
  end

  describe 'no-look-ahead historical freeze' do
    it 'uses campaign.started_at as as_of and ignores an action created during the campaign' do
      create_batch(importer, targets: [target_a, target_b, target_c], at: t0)
      create_batch(importer, targets: [target_a], at: t0 + 10.minutes)
      past = create_moderated_snapshot(historical, linked_ids: [target_a.id], performed_at: t0 - 1.hour)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id], performed_at: t0 + 5.minutes)

      campaign = service.call(FollowImportBatch.where(subject_id: importer.id), now: now)['campaigns'].first

      expect(campaign['as_of']).to eq t0
      expect(campaign['candidate_snapshot_count']).to eq 1
      expect(campaign['matching_snapshot_count']).to eq 1
      expect(campaign.dig('cross_subject', 'best_match', 'snapshot_id')).to eq past.id
      expect(campaign.dig('cross_subject', 'best_match', 'overlap_count')).to eq 1
    end
  end

  describe 'same-subject vs cross-subject and completeness' do
    it 'separates same/cross matches and preserves complete/incomplete/unknown coverage' do
      create_batch(importer, targets: [target_a, target_b], at: t0)
      create_batch(other_importer, targets: [target_b], at: t0)
      create_moderated_snapshot(importer, linked_ids: [target_a.id], reported_count: 1, performed_at: t0 - 2.days)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id], reported_count: 8, performed_at: t0 - 1.day)
      unknown = Fabricate(
        :moderation_evidence_snapshot,
        subject: historical,
        summary: {},
        fingerprint: { 'negative_target_subject_ids' => [target_b.id] }
      )
      Fabricate(:moderation_action, subject: historical, evidence_snapshot: unknown, action_type: :limit, performed_at: t0 - 3.hours)

      result = service.call(FollowImportBatch.where(subject_id: [importer.id, other_importer.id]), now: now)
      importer_campaign = result['campaigns'].find { |row| row['subject_id'] == importer.id }
      other_campaign = result['campaigns'].find { |row| row['subject_id'] == other_importer.id }

      expect(importer_campaign['same_subject']['matching_snapshot_count']).to eq 1
      expect(importer_campaign.dig('same_subject', 'best_match', 'historical_fingerprint_complete')).to be true
      expect(importer_campaign.dig('cross_subject', 'best_match', 'historical_fingerprint_complete')).to be false
      expect(other_campaign.dig('cross_subject', 'best_match', 'historical_fingerprint_complete')).to be_nil
      expect(result.dig('coverage', 'same_subject', 'complete')).to eq 1
      expect(result.dig('coverage', 'cross_subject', 'incomplete')).to eq 1
      expect(result.dig('coverage', 'cross_subject', 'unknown')).to eq 1
      expect(result['coverage']['unknown']).to eq 1
      expect(result['campaigns_with_same_subject_overlap']).to eq 1
      expect(result['campaigns_with_cross_subject_overlap']).to eq 2
    end
  end

  describe 'union overlap vs summed batch overlaps' do
    it 'computes overlap from the campaign union, not the sum of per-batch overlaps' do
      create_batch(importer, targets: [target_a, target_b], at: t0)
      create_batch(importer, targets: [target_b, target_c], at: t0 + 30.seconds)
      create_batch(importer, targets: [target_a, target_c], at: t0 + 90.seconds)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id, target_x.id])

      campaign = service.call(FollowImportBatch.where(subject_id: importer.id), now: now)['campaigns'].first
      match = campaign.dig('cross_subject', 'best_match')

      expect(campaign['batch_count']).to eq 3
      expect(campaign['comparable_unique_target_count']).to eq 3
      expect(match['overlap_count']).to eq 3
      expect(match['current_target_overlap_ratio']).to eq 1.0
      expect(match['stored_negative_containment']).to eq 0.75
      expect(match['jaccard']).to eq 0.75
    end
  end

  describe 'production-style fragmentation regression' do
    it 'collapses closely spaced batches with overlapping target subsets into one factual overlap' do
      create_batch(importer, targets: [target_a, target_b], at: t0)
      create_batch(importer, targets: [target_b], at: t0 + 1.second)
      create_batch(importer, targets: [target_c, target_d], at: t0 + 90.seconds)
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id, target_c.id, target_x.id])

      result = service.call(FollowImportBatch.where(subject_id: importer.id), now: now)
      campaign = result['campaigns'].first
      match = campaign.dig('cross_subject', 'best_match')

      expect(result['campaign_count']).to eq 1
      expect(campaign['comparable_unique_target_count']).to eq 4
      expect(match['historical_subject_id']).to eq historical.id
      expect(match['overlap_count']).to eq 3
      expect(match['current_target_overlap_ratio']).to eq 0.75
    end
  end

  describe 'distributions' do
    it 'excludes no-match campaigns from best-match distributions' do
      overlapping = create_batch(importer, targets: [target_a], at: t0)
      create_batch(other_importer, targets: [target_d], at: t0)
      create_moderated_snapshot(historical, linked_ids: [target_a.id])

      result = service.call([overlapping, FollowImportBatch.find_by!(subject_id: other_importer.id)], now: now)
      cross = result.dig('distributions', 'cross_subject', 'overlap_count')

      expect(result['campaign_count']).to eq 2
      expect(result['campaigns_with_any_overlap']).to eq 1
      expect(cross['n']).to eq 1
      expect(cross['excluded_n']).to eq 1
      expect(cross['min']).to eq 1
      expect(result.dig('distributions', 'same_subject', 'overlap_count', 'n')).to eq 0
      expect(result.dig('distributions', 'same_subject', 'overlap_count', 'excluded_n')).to eq 2
    end
  end

  describe 'empty cohort' do
    it 'returns a stable zero/empty shape' do
      result = service.call([], now: now)

      expect(result['generated_at']).to eq now.iso8601
      expect(result['max_gap_seconds']).to eq 30.minutes.to_f
      expect(result['campaign_count']).to eq 0
      expect(result['subject_count']).to eq 0
      expect(result['campaigns']).to eq []
      expect(result['coverage']).to include('complete' => 0, 'incomplete' => 0, 'unknown' => 0)
      expect(result.dig('distributions', 'cross_subject', 'jaccard', 'n')).to eq 0
      expect(result['elapsed_seconds']).to be >= 0
    end
  end

  describe 'read-only guarantees' do
    it 'does not change moderation, follow-import, or relationship tables' do
      create_batch(importer, targets: [target_a], at: t0)
      create_moderated_snapshot(historical, linked_ids: [target_a.id])

      expect { service.call(FollowImportBatch.all, now: now) }.to_not(change { ledger_counts })
    end
  end
end
# rubocop:enable Metrics/BlockLength
