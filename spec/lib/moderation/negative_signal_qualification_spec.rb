# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::NegativeSignalQualification do
  let(:actor_subject)  { Fabricate(:moderation_subject) }
  let(:target_subject) { Fabricate(:moderation_subject) }
  let(:contacted_at)   { Time.utc(2026, 1, 1, 10, 0, 0) }
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

  describe '.qualified?' do
    it 'reuses PrecedingContactLink.strong_association? and does not invent a rule' do
      event = rejection(occurred_at: contacted_at + 1.hour)

      expect(described_class.qualified?(event)).to be true
      expect(described_class.qualified?(event)).to eq(
        Moderation::PrecedingContactLink.strong_association?(event.preceding_interaction_event, event)
      )
    end

    it 'is false for an unlinked / synthetic Follow Reject' do
      event = rejection(occurred_at: contacted_at + 1.minute, preceding: nil)

      expect(described_class.qualified?(event)).to be false
    end

    it 'is false for nil' do
      expect(described_class.qualified?(nil)).to be false
    end
  end

  describe '.first_qualified_at' do
    it 'returns the earliest qualified occurrence and ignores earlier raw rows' do
      raw = rejection(occurred_at: contacted_at - 1.hour, preceding: nil)
      qualified = rejection(occurred_at: contacted_at + 30.minutes)

      expect(described_class.first_qualified_at([raw, qualified])).to eq qualified.occurred_at
    end

    it 'returns nil when no event is qualified' do
      raw = rejection(occurred_at: contacted_at + 1.minute, preceding: nil)

      expect(described_class.first_qualified_at([raw])).to be_nil
    end
  end
end
