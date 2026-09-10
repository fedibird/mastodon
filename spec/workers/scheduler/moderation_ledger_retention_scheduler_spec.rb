require 'rails_helper'

RSpec.describe Scheduler::ModerationLedgerRetentionScheduler do
  subject { described_class.new }

  describe '#perform' do
    it 'reconciles orphaned subjects by tombstoning them' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        orphan = Fabricate(:moderation_subject)
        orphan.update!(account_id: nil)

        subject.perform

        expect(orphan.reload).to be_tombstoned
        expect(orphan.retention_until).to be_present
      end
    end

    it 'expires an unshared tombstoned subject and its only-participant events' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        expired_a = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
        expired_b = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
        event = Fabricate(:moderation_interaction_event, actor_subject: expired_a, target_subject: expired_b)

        expect { subject.perform }.to change(ModerationSubject, :count).by(-2)

        expect(ModerationSubject.exists?(expired_a.id)).to be false
        expect(ModerationSubject.exists?(expired_b.id)).to be false
        expect(ModerationInteractionEvent.exists?(event.id)).to be false
      end
    end

    it 'keeps shared evidence when only one participant has expired' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        actor  = Fabricate(:account)
        target = Fabricate(:account)

        contact = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :mention)
        rejection = Moderation::EventRecorder.record_rejection(rejector: target, rejected: actor, event_type: :block, preceding_interaction: contact)

        target_subject = rejection.rejector_subject
        actor_subject  = contact.actor_subject
        target_subject.update!(deleted_at: 40.days.ago, retention_until: 10.days.ago)

        expect { subject.perform }.to_not change(ModerationInteractionEvent, :count)
        expect { subject.perform }.to_not change(ModerationRejectionEvent, :count)

        expect(ModerationSubject.exists?(actor_subject.id)).to be true
        expect(ModerationSubject.exists?(target_subject.id)).to be true
        expect(ModerationInteractionEvent.exists?(contact.id)).to be true
        expect(ModerationRejectionEvent.exists?(rejection.id)).to be true

        expect(ModerationInteractionEvent.where(actor_subject_id: actor_subject.id)).to exist
        expect(ModerationRejectionEvent.where(rejected_subject_id: actor_subject.id)).to exist
      end
    end

    it 'does not modify data in dry-run mode' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30', MODERATION_LEDGER_RETENTION_DRY_RUN: 'true' do
        expired = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)

        expect { subject.perform }.to_not change(ModerationSubject, :count)
        expect(ModerationSubject.exists?(expired.id)).to be true
      end
    end

    # Counterpart FKs are ON DELETE SET NULL. SQL `WHERE column NOT IN (...)`
    # does not match NULL, so cleanup must treat a nullified side as "not
    # retained" and delete the event once no retained participant remains.
    it 'deletes an event after one participant is nullified once no retained participant remains' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        retained = Fabricate(:moderation_subject)
        expired  = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
        event = Fabricate(:moderation_interaction_event, actor_subject: retained, target_subject: expired)
        rejection = Fabricate(:moderation_rejection_event, rejector_subject: expired, rejected_subject: retained)

        event.update_columns(target_subject_id: nil)
        rejection.update_columns(rejector_subject_id: nil)

        expect { subject.perform }.to_not change { ModerationInteractionEvent.exists?(event.id) }.from(true)
        expect(ModerationRejectionEvent.exists?(rejection.id)).to be true
        expect(ModerationSubject.exists?(retained.id)).to be true
        expect(ModerationSubject.exists?(expired.id)).to be false

        retained.update!(deleted_at: 40.days.ago, retention_until: 10.days.ago)

        expect { subject.perform }.to change { ModerationInteractionEvent.exists?(event.id) }.from(true).to(false)
        expect(ModerationRejectionEvent.exists?(rejection.id)).to be false
        expect(ModerationSubject.exists?(retained.id)).to be false
      end
    end

    it 'deletes events whose remaining participants are all NULL' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        event = Fabricate(:moderation_interaction_event)
        event.update_columns(actor_subject_id: nil, target_subject_id: nil)

        expect { subject.perform }.to change { ModerationInteractionEvent.exists?(event.id) }.from(true).to(false)
      end
    end
  end
end
