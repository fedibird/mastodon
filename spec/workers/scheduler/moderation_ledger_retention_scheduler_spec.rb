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

    it 'expires tombstoned subjects past retention and cascades their events' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        expired = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
        other   = Fabricate(:moderation_subject)
        event   = Fabricate(:moderation_interaction_event, actor_subject: expired, target_subject: other)

        expect { subject.perform }.to change(ModerationSubject, :count).by(-1)

        expect(ModerationSubject.exists?(expired.id)).to be false
        expect(ModerationInteractionEvent.exists?(event.id)).to be false
        expect(ModerationSubject.exists?(other.id)).to be true
      end
    end

    it 'does not modify data in dry-run mode' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30', MODERATION_LEDGER_RETENTION_DRY_RUN: 'true' do
        expired = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)

        expect { subject.perform }.to_not change(ModerationSubject, :count)
        expect(ModerationSubject.exists?(expired.id)).to be true
      end
    end
  end
end
