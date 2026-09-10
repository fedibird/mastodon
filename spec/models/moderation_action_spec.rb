require 'rails_helper'

RSpec.describe ModerationAction, type: :model do
  it 'is valid with the required attributes' do
    expect(Fabricate.build(:moderation_action)).to be_valid
  end

  it 'requires an action_type and performed_at' do
    action = Fabricate.build(:moderation_action, action_type: nil, performed_at: nil)
    expect(action).to_not be_valid
    expect(action.errors.attribute_names).to include(:action_type, :performed_at)
  end

  it 'exposes the action types' do
    expect(described_class.action_types.keys).to match_array(%w(warn limit freeze suspend delete other))
  end

  it 'optionally links a moderator and an evidence snapshot' do
    moderator = Fabricate(:account)
    snapshot  = Fabricate(:moderation_evidence_snapshot)
    action    = Fabricate(:moderation_action, moderator_account: moderator, evidence_snapshot: snapshot)

    expect(action.moderator_account).to eq moderator
    expect(action.evidence_snapshot).to eq snapshot
  end
end
