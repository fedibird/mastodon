require 'rails_helper'

RSpec.describe ModerationRejectionEvent, type: :model do
  it 'is valid with the required attributes' do
    expect(Fabricate.build(:moderation_rejection_event)).to be_valid
  end

  it 'requires an event_type, occurred_at and observed_at' do
    event = Fabricate.build(:moderation_rejection_event, event_type: nil, occurred_at: nil, observed_at: nil)
    expect(event).to_not be_valid
    expect(event.errors.attribute_names).to include(:event_type, :occurred_at, :observed_at)
  end

  it 'exposes the rejection event types' do
    expect(described_class.event_types.keys).to match_array(%w(follow_reject remove_follower mute mute_notifications block report))
  end

  describe '#time_to_rejection' do
    it 'is nil without a preceding interaction' do
      expect(Fabricate(:moderation_rejection_event, preceding_interaction_event: nil).time_to_rejection).to be_nil
    end

    it 'is the elapsed seconds since the preceding interaction' do
      contact = Fabricate(:moderation_interaction_event, occurred_at: Time.utc(2026, 1, 1, 10, 0, 0))
      rejection = Fabricate(:moderation_rejection_event, preceding_interaction_event: contact, occurred_at: Time.utc(2026, 1, 1, 10, 15, 0))

      expect(rejection.time_to_rejection).to eq 15.minutes.to_i
    end
  end
end
