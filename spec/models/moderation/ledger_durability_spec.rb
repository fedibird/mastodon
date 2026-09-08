require 'rails_helper'

# The most important guarantee of the moderation ledger (Phase 1/2 design):
# observed events must survive deletion/purge of the underlying Mastodon
# records. The ledger references ModerationSubject (never Account directly),
# and the only Account link (moderation_subjects.account_id) is ON DELETE SET
# NULL, so nothing in the ledger is cascade-deleted by Mastodon's lifecycle.
RSpec.describe 'Moderation ledger durability', type: :model do
  let(:actor)  { Fabricate(:account) }
  let(:target) { Fabricate(:account) }

  describe 'when the acting account is deleted' do
    it 'keeps the subject and interaction event, only nullifying account_id' do
      event = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :follow)
      actor_subject_id = event.actor_subject_id

      expect { actor.destroy! }.to_not change(ModerationInteractionEvent, :count)

      expect(ModerationSubject.exists?(actor_subject_id)).to be true
      expect(ModerationSubject.find(actor_subject_id).account_id).to be_nil
      expect(ModerationInteractionEvent.exists?(event.id)).to be true
      expect(event.reload.actor_subject_id).to eq actor_subject_id
    end
  end

  describe 'when the rejecting account is deleted' do
    it 'keeps the rejection event, only nullifying account_id' do
      contact = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :mention)
      rejection = Moderation::EventRecorder.record_rejection(rejector: target, rejected: actor, event_type: :block, preceding_interaction: contact)
      rejector_subject_id = rejection.rejector_subject_id

      expect { target.destroy! }.to_not change(ModerationRejectionEvent, :count)

      expect(ModerationSubject.find(rejector_subject_id).account_id).to be_nil
      expect(ModerationRejectionEvent.exists?(rejection.id)).to be true
    end
  end

  describe 'when the source status is deleted' do
    it 'keeps the interaction event and its status_id pointer' do
      status = Fabricate(:status, account: actor)
      event = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :mention, status: status)

      expect { status.destroy! }.to_not change(ModerationInteractionEvent, :count)

      expect(ModerationInteractionEvent.exists?(event.id)).to be true
      expect(event.reload.status_id).to eq status.id
    end
  end

  describe 'when both accounts are deleted' do
    it 'preserves the interaction event with both subjects detached' do
      event = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :follow)

      actor.destroy!
      target.destroy!

      event.reload
      expect(event.actor_subject.account_id).to be_nil
      expect(event.target_subject.account_id).to be_nil
    end
  end
end
