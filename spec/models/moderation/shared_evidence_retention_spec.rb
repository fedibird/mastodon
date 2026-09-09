require 'rails_helper'

# Regression for the shared-evidence retention bug: expiring B must not erase
# A→B contacts or B→A rejections while A is still retained.
RSpec.describe 'Moderation shared evidence retention', type: :model do
  it 'keeps A\'s contact and rejection evidence after B tombstones and expires' do
    ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
      alice = Fabricate(:account, username: 'alice_retained')
      bob   = Fabricate(:account, username: 'bob_expired')

      contact = Moderation::EventRecorder.record_interaction(actor: alice, target: bob, event_type: :follow)
      rejection = Moderation::EventRecorder.record_rejection(
        rejector: bob,
        rejected: alice,
        event_type: :block,
        preceding_interaction: contact
      )

      alice_subject = contact.actor_subject
      bob_subject   = contact.target_subject

      bob_subject.tombstone!(now: 40.days.ago)

      Scheduler::ModerationLedgerRetentionScheduler.new.perform

      expect(ModerationSubject.exists?(alice_subject.id)).to be true
      expect(ModerationInteractionEvent.exists?(contact.id)).to be true
      expect(ModerationRejectionEvent.exists?(rejection.id)).to be true

      expect(ModerationInteractionEvent.where(actor_subject_id: alice_subject.id, target_subject_id: bob_subject.id)).to exist
      expect(ModerationRejectionEvent.where(rejector_subject_id: bob_subject.id, rejected_subject_id: alice_subject.id)).to exist

      expect(alice_subject.reload).to_not be_tombstoned
      expect(bob_subject.reload).to be_tombstoned
    end
  end
end
