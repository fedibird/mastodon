require 'rails_helper'

RSpec.describe Moderation::EvidenceSnapshotService, type: :service do
  let(:actor) { Fabricate(:account, username: 'actor') }
  let(:a)     { Fabricate(:account, username: 'aaa') }
  let(:b)     { Fabricate(:account, username: 'bbb') }
  let(:c)     { Fabricate(:account, username: 'ccc') }
  let(:d)     { Fabricate(:account, username: 'ddd') }

  it 'summarises interactions/rejections and captures the negative target set' do
    Moderation::EventRecorder.record_interaction(actor: actor, target: a, event_type: :mention)
    Moderation::EventRecorder.record_interaction(actor: actor, target: b, event_type: :follow)
    Moderation::EventRecorder.record_interaction(actor: actor, target: c, event_type: :mention)

    # a and b were contacted and rejected the actor -> negative targets.
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
    expect(snapshot.summary['negative_target_count']).to eq 2

    a_subject = ModerationSubject.find_by(account_id: a.id)
    b_subject = ModerationSubject.find_by(account_id: b.id)
    expect(snapshot.negative_target_subject_ids).to match_array([a_subject.id, b_subject.id])

    expect(snapshot.schema_version).to eq described_class::SCHEMA_VERSION
    expect(snapshot.window_end).to be_present
    expect(snapshot.window_start).to be_present
  end

  it 'respects the window boundary' do
    Moderation::EventRecorder.record_interaction(actor: actor, target: a, event_type: :mention, occurred_at: 100.days.ago)

    snapshot = described_class.new.call(actor, window: 30.days)
    expect(snapshot.summary['interactions_count']).to eq 0
  end
end
