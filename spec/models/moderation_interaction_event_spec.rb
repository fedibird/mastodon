require 'rails_helper'

RSpec.describe ModerationInteractionEvent, type: :model do
  it 'is valid with the required attributes' do
    expect(Fabricate.build(:moderation_interaction_event)).to be_valid
  end

  it 'requires an event_type, occurred_at and observed_at' do
    event = Fabricate.build(:moderation_interaction_event, event_type: nil, occurred_at: nil, observed_at: nil)
    expect(event).to_not be_valid
    expect(event.errors.attribute_names).to include(:event_type, :occurred_at, :observed_at)
  end

  it 'belongs to actor and target subjects' do
    actor = Fabricate(:moderation_subject)
    target = Fabricate(:moderation_subject)
    event = Fabricate(:moderation_interaction_event, actor_subject: actor, target_subject: target)

    expect(event.actor_subject).to eq actor
    expect(event.target_subject).to eq target
    expect(actor.actor_interaction_events).to include(event)
    expect(target.target_interaction_events).to include(event)
  end

  it 'exposes the interaction event types' do
    expect(described_class.event_types.keys).to match_array(%w(mention reply follow quote reference reaction favourite follow_import))
  end
end
