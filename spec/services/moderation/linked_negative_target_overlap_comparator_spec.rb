# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::LinkedNegativeTargetOverlapComparator do
  subject(:comparator) { described_class.new }

  let(:as_of) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:subject_row) { Fabricate(:moderation_subject) }
  let(:other) { Fabricate(:moderation_subject) }
  let(:target_a) { Fabricate(:moderation_subject) }
  let(:target_b) { Fabricate(:moderation_subject) }

  def create_snapshot(owner, linked_ids:, performed_at: as_of - 1.hour)
    snapshot = Fabricate(
      :moderation_evidence_snapshot,
      subject: owner,
      summary: { 'linked_negative_target_count' => linked_ids.size },
      fingerprint: { 'linked_negative_target_subject_ids' => linked_ids }
    )
    Fabricate(:moderation_action, subject: owner, evidence_snapshot: snapshot, action_type: :suspend, performed_at: performed_at)
    snapshot
  end

  it 'compares a supplied target set at as_of without requiring a Follow Import batch' do
    snapshot = create_snapshot(other, linked_ids: [target_a.id, target_b.id])

    result = comparator.call(
      subject_id: subject_row.id,
      comparable_ids: [target_a.id, nil, target_a.id],
      as_of: as_of,
      counts: { target_rows: 3, unresolved: 1 }
    )

    expect(result['batch_id']).to be_nil
    expect(result['subject_id']).to eq subject_row.id
    expect(result['as_of']).to eq as_of
    expect(result['target_rows']).to eq 3
    expect(result['comparable_unique_target_count']).to eq 1
    expect(result['unresolved_or_unmapped_target_rows']).to eq 1
    expect(result['matches'].first['snapshot_id']).to eq snapshot.id
    expect(result['matches'].first['same_subject']).to be false
    expect(result['matches'].first['overlap_count']).to eq 1
  end

  it 'does not use a later action as historical evidence' do
    create_snapshot(other, linked_ids: [target_a.id], performed_at: as_of + 1.minute)

    result = comparator.call(
      subject_id: subject_row.id,
      comparable_ids: [target_a.id],
      as_of: as_of,
      counts: { target_rows: 1, unresolved: 0 }
    )

    expect(result['candidate_snapshot_count']).to eq 0
    expect(result['matches']).to eq []
  end
end
