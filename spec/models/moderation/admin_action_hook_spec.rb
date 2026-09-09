require 'rails_helper'

# Phase 4 / PR 5: a moderator action taken through Admin::AccountAction records
# a ModerationAction plus an evidence snapshot into the ledger.
RSpec.describe 'Moderation admin action hook', type: :model do
  let(:moderator) { Fabricate(:account, user: Fabricate(:user, admin: true)) }
  let(:target)    { Fabricate(:account, user: Fabricate(:user)) }

  def perform(type)
    action = Admin::AccountAction.new
    action.assign_attributes(type: type, current_account: moderator, target_account: target)
    action.save!
  end

  it 'records a freeze action with an evidence snapshot when disabling' do
    expect { perform('disable') }.to change(ModerationAction, :count).by(1).and change(ModerationEvidenceSnapshot, :count).by(1)

    action = ModerationAction.last
    expect(action.action_type).to eq 'freeze'
    expect(action.subject.account_id).to eq target.id
    expect(action.moderator_account_id).to eq moderator.id
    expect(action.reason_code).to eq 'disable'
    expect(action.evidence_snapshot).to be_present
  end

  it 'maps silence to a limit action' do
    expect { perform('silence') }.to change(ModerationAction, :count).by(1)
    expect(ModerationAction.last.action_type).to eq 'limit'
  end
end
