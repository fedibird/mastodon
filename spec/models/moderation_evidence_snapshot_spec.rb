require 'rails_helper'

RSpec.describe ModerationEvidenceSnapshot, type: :model do
  it 'is valid with the required attributes' do
    expect(Fabricate.build(:moderation_evidence_snapshot)).to be_valid
  end

  it 'requires a positive integer schema_version' do
    expect(Fabricate.build(:moderation_evidence_snapshot, schema_version: 0)).to_not be_valid
  end

  it 'reads the negative target set from the fingerprint' do
    snapshot = Fabricate(:moderation_evidence_snapshot, fingerprint: { 'negative_target_subject_ids' => [1, 2, 3] })
    expect(snapshot.negative_target_subject_ids).to eq [1, 2, 3]
  end

  it 'reads the weak same-window correlation set separately from causal targets' do
    snapshot = Fabricate(
      :moderation_evidence_snapshot,
      fingerprint: {
        'negative_target_subject_ids' => [1],
        'correlated_negative_target_subject_ids' => [2, 3],
      }
    )
    expect(snapshot.negative_target_subject_ids).to eq [1]
    expect(snapshot.correlated_negative_target_subject_ids).to eq [2, 3]
  end
end
