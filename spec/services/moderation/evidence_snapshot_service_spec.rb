require 'rails_helper'

RSpec.describe Moderation::EvidenceSnapshotService, type: :service do
  let(:actor) { Fabricate(:account, username: 'actor') }
  let(:a)     { Fabricate(:account, username: 'aaa') }
  let(:b)     { Fabricate(:account, username: 'bbb') }
  let(:c)     { Fabricate(:account, username: 'ccc') }
  let(:d)     { Fabricate(:account, username: 'ddd') }

  def subject_for(account)
    ModerationSubject.find_by(account_id: account.id)
  end

  it 'summarises interactions/rejections and captures the linked negative target set' do
    Moderation::EventRecorder.record_interaction(actor: actor, target: a, event_type: :mention)
    Moderation::EventRecorder.record_interaction(actor: actor, target: b, event_type: :follow)
    Moderation::EventRecorder.record_interaction(actor: actor, target: c, event_type: :mention)

    # a and b were contacted and then rejected the actor -> linked negative targets.
    Moderation::EventRecorder.record_rejection(rejector: a, rejected: actor, event_type: :block)
    Moderation::EventRecorder.record_rejection(rejector: b, rejected: actor, event_type: :report)
    # d rejected the actor but was never contacted -> responder, not a target.
    Moderation::EventRecorder.record_rejection(rejector: d, rejected: actor, event_type: :block)

    snapshot = described_class.new.call(actor)

    expect(snapshot.summary['interactions_count']).to eq 3
    expect(snapshot.summary['unique_contacts']).to eq 3
    expect(snapshot.summary['blocks_received']).to eq 2
    expect(snapshot.summary['reports_received']).to eq 1
    expect(snapshot.summary['negative_responders']).to eq 3
    expect(snapshot.summary['linked_negative_target_count']).to eq 2
    expect(snapshot.summary['correlated_negative_target_count']).to eq 0

    expect(snapshot.linked_negative_target_subject_ids).to match_array([subject_for(a).id, subject_for(b).id])
    expect(snapshot.correlated_negative_target_subject_ids).to be_empty

    expect(snapshot.schema_version).to eq described_class::SCHEMA_VERSION
    expect(snapshot.window_end).to be_present
    expect(snapshot.window_start).to be_present
    expect(snapshot.fingerprint['coverage']).to eq described_class::INBOUND_ACTIVITYPUB_COVERAGE
    # Every modeled inbound type is hooked (deferred is empty)...
    expect(snapshot.fingerprint.dig('coverage', 'observed_inbound_event_types')).to include('follow_reject')
    expect(snapshot.fingerprint.dig('coverage', 'deferred_inbound_event_types')).to eq []
    # ...but a known recorder-only-failure gap keeps coverage honestly partial,
    # so downstream analysis does not read missing evidence as absence of behaviour.
    expect(snapshot.fingerprint.dig('coverage', 'complete_for_remote_subjects')).to be false
    expect(snapshot.fingerprint.dig('coverage', 'inbound_activitypub')).to eq 'partial'
    gaps = snapshot.fingerprint.dig('coverage', 'known_inbound_recording_gaps')
    expect(gaps).to include(a_hash_including('event_type' => 'follow_reject', 'shape' => 'bare_follow_request_uri', 'repairable' => false))
  end

  it 'does not put unordered same-window overlap into linked_negative_target_subject_ids' do
    # B rejects A first, then A contacts B — same snapshot window, no preceding-contact link.
    Moderation::EventRecorder.record_rejection(rejector: a, rejected: actor, event_type: :block, occurred_at: 2.hours.ago)
    Moderation::EventRecorder.record_interaction(actor: actor, target: a, event_type: :mention, occurred_at: 1.hour.ago)

    snapshot = described_class.new.call(actor)

    expect(snapshot.summary['interactions_count']).to eq 1
    expect(snapshot.summary['blocks_received']).to eq 1
    expect(snapshot.summary['linked_negative_target_count']).to eq 0
    expect(snapshot.linked_negative_target_subject_ids).to be_empty
    expect(snapshot.summary['correlated_negative_target_count']).to eq 1
    expect(snapshot.correlated_negative_target_subject_ids).to eq [subject_for(a).id]
  end

  it 'treats an unlinked same-window pair as a weak correlation, not a linked target' do
    actor_subject = ModerationSubject.for_account!(actor)
    a_subject     = ModerationSubject.for_account!(a)

    Fabricate(
      :moderation_interaction_event,
      actor_subject: actor_subject,
      target_subject: a_subject,
      event_type: :mention,
      occurred_at: 3.hours.ago
    )
    Fabricate(
      :moderation_rejection_event,
      rejector_subject: a_subject,
      rejected_subject: actor_subject,
      event_type: :block,
      preceding_interaction_event: nil,
      occurred_at: 1.hour.ago
    )

    snapshot = described_class.new.call(actor)

    expect(snapshot.linked_negative_target_subject_ids).to be_empty
    expect(snapshot.correlated_negative_target_subject_ids).to eq [a_subject.id]
  end

  it 'omits nullified counterpart ids from fingerprints and contact counts' do
    actor_subject = ModerationSubject.for_account!(actor)
    a_subject     = ModerationSubject.for_account!(a)
    b_subject     = ModerationSubject.for_account!(b)

    kept = Fabricate(
      :moderation_interaction_event,
      actor_subject: actor_subject,
      target_subject: a_subject,
      event_type: :mention,
      occurred_at: 2.hours.ago
    )
    orphan_contact = Fabricate(
      :moderation_interaction_event,
      actor_subject: actor_subject,
      target_subject: b_subject,
      event_type: :follow,
      occurred_at: 2.hours.ago
    )
    orphan_contact.update_columns(target_subject_id: nil)

    Fabricate(
      :moderation_rejection_event,
      rejector_subject: a_subject,
      rejected_subject: actor_subject,
      preceding_interaction_event: kept,
      event_type: :block,
      occurred_at: 1.hour.ago
    )
    orphan_rejection = Fabricate(
      :moderation_rejection_event,
      rejector_subject: b_subject,
      rejected_subject: actor_subject,
      event_type: :block,
      occurred_at: 1.hour.ago
    )
    orphan_rejection.update_columns(rejector_subject_id: nil)

    snapshot = described_class.new.call(actor)

    expect(snapshot.summary['interactions_count']).to eq 2
    expect(snapshot.summary['unique_contacts']).to eq 1
    expect(snapshot.linked_negative_target_subject_ids).to eq [a_subject.id]
    expect(snapshot.linked_negative_target_subject_ids).to_not include(nil)
    expect(snapshot.correlated_negative_target_subject_ids).to be_empty
    expect(snapshot.fingerprint['linked_negative_target_subject_ids']).to_not include(nil)
  end

  it 'respects the window boundary' do
    Moderation::EventRecorder.record_interaction(actor: actor, target: a, event_type: :mention, occurred_at: 100.days.ago)

    snapshot = described_class.new.call(actor, window: 30.days)
    expect(snapshot.summary['interactions_count']).to eq 0
  end
end
