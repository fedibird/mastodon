require 'rails_helper'

RSpec.describe Moderation::PrecedingContactLink do
  let(:actor_subject)    { Fabricate(:moderation_subject) }
  let(:target_subject)   { Fabricate(:moderation_subject) }
  let(:contacted_at)     { Time.utc(2026, 1, 1, 10, 0, 0) }
  let(:interaction) do
    Fabricate(
      :moderation_interaction_event,
      actor_subject: actor_subject,
      target_subject: target_subject,
      occurred_at: contacted_at
    )
  end

  def rejection(occurred_at:, preceding: interaction)
    Fabricate(
      :moderation_rejection_event,
      rejector_subject: target_subject,
      rejected_subject: actor_subject,
      preceding_interaction_event: preceding,
      occurred_at: occurred_at
    )
  end

  describe '.strong_association?' do
    it 'is true when the rejection follows the matching contact within the window' do
      expect(described_class.strong_association?(interaction, rejection(occurred_at: contacted_at + 1.hour))).to be true
    end

    it 'is false when the rejection occurs before the contact' do
      expect(described_class.strong_association?(interaction, rejection(occurred_at: contacted_at - 1.hour, preceding: nil))).to be false
    end

    it 'is false when the elapsed time exceeds MAX_WINDOW' do
      expect(described_class.strong_association?(interaction, rejection(occurred_at: contacted_at + described_class::MAX_WINDOW + 1.second))).to be false
    end

    it 'is false when the interaction pair is reversed' do
      reversed = Fabricate(
        :moderation_interaction_event,
        actor_subject: target_subject,
        target_subject: actor_subject,
        occurred_at: contacted_at
      )
      expect(described_class.strong_association?(reversed, rejection(occurred_at: contacted_at + 1.minute, preceding: reversed))).to be false
    end

    it 'is false without a preceding interaction' do
      expect(described_class.strong_association?(nil, rejection(occurred_at: contacted_at + 1.minute, preceding: nil))).to be false
    end

    it 'is false when any participant id is nil' do
      nullified = Fabricate(
        :moderation_interaction_event,
        actor_subject: actor_subject,
        target_subject: target_subject,
        occurred_at: contacted_at
      )
      nullified.update_columns(actor_subject_id: nil, target_subject_id: nil)
      orphan_rejection = Fabricate(
        :moderation_rejection_event,
        rejector_subject: target_subject,
        rejected_subject: actor_subject,
        preceding_interaction_event: nullified,
        occurred_at: contacted_at + 1.minute
      )
      orphan_rejection.update_columns(rejector_subject_id: nil, rejected_subject_id: nil)

      expect(described_class.strong_association?(nullified, orphan_rejection)).to be false
      expect(
        described_class.valid_pair?(
          nullified,
          rejected_subject_id: nil,
          rejector_subject_id: nil,
          occurred_at: contacted_at + 1.minute
        )
      ).to be false
    end
  end

  describe '.find_preceding_interaction' do
    it 'returns the nearest earlier contact from rejected to rejector' do
      older = Fabricate(
        :moderation_interaction_event,
        actor_subject: actor_subject,
        target_subject: target_subject,
        occurred_at: contacted_at - 2.hours
      )
      newer = interaction

      found = described_class.find_preceding_interaction(
        rejected_subject: actor_subject,
        rejector_subject: target_subject,
        occurred_at: contacted_at + 5.minutes
      )

      expect(found).to eq newer
      expect(found).to_not eq older
    end

    it 'ignores contacts after the rejection' do
      earlier = interaction
      Fabricate(
        :moderation_interaction_event,
        actor_subject: actor_subject,
        target_subject: target_subject,
        occurred_at: contacted_at + 1.hour
      )

      found = described_class.find_preceding_interaction(
        rejected_subject: actor_subject,
        rejector_subject: target_subject,
        occurred_at: contacted_at
      )

      expect(found).to eq earlier
    end
  end
end
