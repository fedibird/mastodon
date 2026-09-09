require 'rails_helper'

RSpec.describe Moderation::EventRecorder, type: :service do
  let(:actor)  { Fabricate(:account) }
  let(:target) { Fabricate(:account) }

  describe '.record_interaction' do
    it 'records an interaction event, resolving accounts to subjects' do
      status = Fabricate(:status, account: actor)

      event = described_class.record_interaction(
        actor: actor,
        target: target,
        event_type: :mention,
        status: status,
        source_record: status
      )

      expect(event).to be_persisted
      expect(event.event_type).to eq 'mention'
      expect(event.actor_subject.account_id).to eq actor.id
      expect(event.target_subject.account_id).to eq target.id
      expect(event.status_id).to eq status.id
      expect(event.source_record_type).to eq 'Status'
      expect(event.source_record_id).to eq status.id
    end

    it 'reuses the same subject for repeated interactions by the same account' do
      described_class.record_interaction(actor: actor, target: target, event_type: :follow)
      described_class.record_interaction(actor: actor, target: target, event_type: :mention)

      expect(ModerationSubject.where(account_id: actor.id).count).to eq 1
      expect(ModerationInteractionEvent.count).to eq 2
    end

    it 'does not raise and returns nil on failure, and records no event' do
      allow(Rails.logger).to receive(:warn).and_call_original

      result = nil
      expect do
        result = described_class.record_interaction(actor: actor, target: nil, event_type: :follow)
      end.to_not change(ModerationInteractionEvent, :count)

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/Moderation::EventRecorder/)
    end
  end

  describe '.record_rejection' do
    it 'records a rejection event and links the preceding interaction' do
      contact = described_class.record_interaction(actor: actor, target: target, event_type: :mention)

      event = described_class.record_rejection(
        rejector: target,
        rejected: actor,
        event_type: :block,
        preceding_interaction: contact
      )

      expect(event).to be_persisted
      expect(event.event_type).to eq 'block'
      expect(event.rejector_subject.account_id).to eq target.id
      expect(event.rejected_subject.account_id).to eq actor.id
      expect(event.preceding_interaction_event).to eq contact
    end

    it 'does not raise and returns nil on failure' do
      allow(Rails.logger).to receive(:warn)

      result = nil
      expect do
        result = described_class.record_rejection(rejector: nil, rejected: actor, event_type: :block)
      end.to_not change(ModerationRejectionEvent, :count)

      expect(result).to be_nil
    end
  end
end
