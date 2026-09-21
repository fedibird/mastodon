# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::FollowImportNegativeTargetOverlapService do
  subject(:service) { described_class.new }

  let(:imported_at) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:importer) { Fabricate(:moderation_subject) }
  let(:other_subject) { Fabricate(:moderation_subject) }
  let(:target_a) { Fabricate(:moderation_subject) }
  let(:target_b) { Fabricate(:moderation_subject) }
  let(:target_c) { Fabricate(:moderation_subject) }
  let(:target_x) { Fabricate(:moderation_subject) }

  def create_batch(subject, targets: [], unresolved: 0, at: imported_at)
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
      batch.targets.create!(target_key_hash: "unresolved-#{index}", position: targets.size + index)
    end

    batch
  end

  def create_moderated_snapshot(subject, linked_ids:, correlated_ids: [], reported_count: nil, performed_at: imported_at - 1.day, action_type: :suspend)
    snapshot = Fabricate(
      :moderation_evidence_snapshot,
      subject: subject,
      summary: { 'linked_negative_target_count' => reported_count || linked_ids.size },
      fingerprint: {
        'linked_negative_target_subject_ids' => linked_ids,
        'correlated_negative_target_subject_ids' => correlated_ids,
      }
    )

    Fabricate(
      :moderation_action,
      subject: subject,
      evidence_snapshot: snapshot,
      action_type: action_type,
      performed_at: performed_at
    )

    snapshot
  end

  describe 'basic linked-negative overlap' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b, target_c]) }
    let!(:snapshot) do
      create_moderated_snapshot(
        other_subject,
        linked_ids: [target_a.id, target_b.id, target_x.id]
      )
    end

    it 'reports intersection, ratios, and Jaccard from stored linked-negative IDs only' do
      result = service.call(batch)

      expect(result['batch_id']).to eq batch.id
      expect(result['subject_id']).to eq importer.id
      expect(result['as_of']).to eq imported_at
      expect(result['target_rows']).to eq 3
      expect(result['comparable_unique_target_count']).to eq 3
      expect(result['unresolved_or_unmapped_target_rows']).to eq 0
      expect(result['candidate_snapshot_count']).to eq 1
      expect(result['matching_snapshot_count']).to eq 1

      match = result['matches'].first
      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['historical_subject_id']).to eq other_subject.id
      expect(match['same_subject']).to be false
      expect(match['action_types']).to eq ['suspend']
      expect(match['stored_linked_negative_target_count']).to eq 3
      expect(match['reported_linked_negative_target_count']).to eq 3
      expect(match['historical_fingerprint_complete']).to be true
      expect(match['overlap_count']).to eq 2
      expect(match['current_target_overlap_ratio']).to eq(2.0 / 3)
      expect(match['stored_negative_containment']).to eq(2.0 / 3)
      expect(match['jaccard']).to eq 0.5
    end
  end

  describe 'duplicate current targets' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_a, target_b]) }
    let!(:snapshot) do
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id, target_x.id])
    end

    it 'counts duplicate target rows once in the comparable set' do
      result = service.call(batch)

      expect(result['target_rows']).to eq 3
      expect(result['comparable_unique_target_count']).to eq 2
      expect(result['matches'].first['overlap_count']).to eq 1
      expect(result['matches'].first['current_target_overlap_ratio']).to eq 0.5
    end
  end

  describe 'unresolved targets' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b], unresolved: 2) }
    let!(:snapshot) do
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id, target_x.id])
    end

    it 'reports NULL target_subject_id rows without using them as overlap denominator' do
      result = service.call(batch)

      expect(result['target_rows']).to eq 4
      expect(result['comparable_unique_target_count']).to eq 2
      expect(result['unresolved_or_unmapped_target_rows']).to eq 2
      expect(result['matches'].first['overlap_count']).to eq 1
      expect(result['matches'].first['current_target_overlap_ratio']).to eq 0.5
    end
  end

  describe 'correlated-only evidence' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b, target_c]) }

    before do
      create_moderated_snapshot(
        other_subject,
        linked_ids: [],
        correlated_ids: [target_a.id, target_b.id],
        reported_count: 0
      )
    end

    it 'does not treat correlated_negative_target_subject_ids as a match' do
      result = service.call(batch)

      expect(result['candidate_snapshot_count']).to eq 1
      expect(result['matching_snapshot_count']).to eq 0
      expect(result['matches']).to eq []
    end
  end

  describe 'no look-ahead' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b, target_c]) }
    let!(:past_snapshot) do
      create_moderated_snapshot(
        other_subject,
        linked_ids: [target_a.id],
        performed_at: imported_at - 1.hour
      )
    end
    let!(:future_snapshot) do
      create_moderated_snapshot(
        Fabricate(:moderation_subject),
        linked_ids: [target_a.id, target_b.id, target_c.id],
        performed_at: imported_at + 1.hour
      )
    end

    it 'ignores a moderation action performed after as_of, including the default imported_at cutoff' do
      result = service.call(batch)

      expect(result['as_of']).to eq imported_at
      expect(result['candidate_snapshot_count']).to eq 1
      expect(result['matching_snapshot_count']).to eq 1
      expect(result['matches'].map { |row| row['snapshot_id'] }).to eq [past_snapshot.id]
      expect(result['matches'].map { |row| row['snapshot_id'] }).to_not include(future_snapshot.id)
    end

    it 'keeps a snapshot whose earlier action is eligible and omits later actions from metadata' do
      later = Fabricate(
        :moderation_action,
        subject: other_subject,
        evidence_snapshot: past_snapshot,
        action_type: :delete,
        performed_at: imported_at + 2.hours
      )

      result = service.call(batch)
      match = result['matches'].first

      expect(result['candidate_snapshot_count']).to eq 1
      expect(match['action_ids']).to_not include(later.id)
      expect(match['action_types']).to eq ['suspend']
      expect(match['latest_action_performed_at']).to be <= imported_at
    end
  end

  describe 'same-subject marker' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b]) }
    let!(:snapshot) do
      create_moderated_snapshot(importer, linked_ids: [target_a.id, target_x.id])
    end

    it 'includes a historical snapshot for the same subject and marks same_subject true' do
      match = service.call(batch)['matches'].first

      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['historical_subject_id']).to eq importer.id
      expect(match['same_subject']).to be true
    end
  end

  describe 'cross-subject marker' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b]) }
    let!(:snapshot) do
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id])
    end

    it 'does not infer that another subject is the same person' do
      match = service.call(batch)['matches'].first

      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['historical_subject_id']).to eq other_subject.id
      expect(match['historical_subject_id']).to_not eq importer.id
      expect(match['same_subject']).to be false
    end
  end

  describe 'fingerprint truncation' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b, target_c]) }
    let!(:snapshot) do
      create_moderated_snapshot(
        other_subject,
        linked_ids: [target_a.id.to_s, target_b.id],
        reported_count: 8
      )
    end

    it 'exposes incomplete coverage and calculates metrics only from stored IDs' do
      match = service.call(batch)['matches'].first

      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['stored_linked_negative_target_count']).to eq 2
      expect(match['reported_linked_negative_target_count']).to eq 8
      expect(match['historical_fingerprint_complete']).to be false
      expect(match['overlap_count']).to eq 2
      expect(match['current_target_overlap_ratio']).to eq(2.0 / 3)
      expect(match['stored_negative_containment']).to eq 1.0
      expect(match['jaccard']).to eq(2.0 / 3)
    end
  end

  describe 'no-overlap' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b]) }

    before do
      create_moderated_snapshot(other_subject, linked_ids: [target_x.id])
      Fabricate(
        :moderation_evidence_snapshot,
        subject: other_subject,
        fingerprint: { 'linked_negative_target_subject_ids' => [target_a.id] }
      )
    end

    it 'returns no match rows and a zero matching count' do
      result = service.call(batch)

      expect(result['candidate_snapshot_count']).to eq 1
      expect(result['matching_snapshot_count']).to eq 0
      expect(result['matches']).to eq []
    end
  end

  describe 'read-only guarantees' do
    let!(:batch) { create_batch(importer, targets: [target_a], unresolved: 1) }

    before do
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id])
    end

    it 'does not change subjects, interactions, rejections, actions, snapshots, batches, targets, follows, blocks, or mutes' do
      expect { service.call(batch) }.to_not change {
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
      }
    end
  end

  describe 'tombstoned historical subject' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b]) }
    let!(:historical) { Fabricate(:moderation_subject) }
    let!(:snapshot) do
      create_moderated_snapshot(historical, linked_ids: [target_a.id, target_x.id])
    end

    before do
      historical.tombstone!
    end

    it 'still matches deletion-safe retained evidence' do
      expect(historical.reload).to be_tombstoned

      result = service.call(batch)
      match = result['matches'].first

      expect(result['matching_snapshot_count']).to eq 1
      expect(match['snapshot_id']).to eq snapshot.id
      expect(match['historical_subject_id']).to eq historical.id
      expect(match['overlap_count']).to eq 1
    end
  end

  describe 'match ordering' do
    let!(:batch) { create_batch(importer, targets: [target_a, target_b, target_c]) }
    let!(:weaker) do
      create_moderated_snapshot(
        other_subject,
        linked_ids: [target_a.id],
        performed_at: imported_at - 1.hour
      )
    end
    let!(:stronger) do
      create_moderated_snapshot(
        Fabricate(:moderation_subject),
        linked_ids: [target_a.id, target_b.id],
        performed_at: imported_at - 2.hours
      )
    end

    it 'sorts strongest factual overlap first' do
      ids = service.call(batch)['matches'].map { |row| row['snapshot_id'] }
      expect(ids).to eq [stronger.id, weaker.id]
    end
  end
end
