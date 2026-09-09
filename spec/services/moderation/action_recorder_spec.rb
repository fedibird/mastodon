require 'rails_helper'

RSpec.describe Moderation::ActionRecorder, type: :service do
  let(:account)   { Fabricate(:account) }
  let(:moderator) { Fabricate(:account) }

  describe '.record' do
    it 'records an action and generates an evidence snapshot' do
      expect { described_class.record(account: account, action_type: :suspend, moderator: moderator, reason_code: 'suspend') }
        .to change(ModerationAction, :count).by(1)
        .and change(ModerationEvidenceSnapshot, :count).by(1)

      action = ModerationAction.last
      expect(action.action_type).to eq 'suspend'
      expect(action.subject.account_id).to eq account.id
      expect(action.moderator_account_id).to eq moderator.id
      expect(action.reason_code).to eq 'suspend'
      expect(action.evidence_snapshot).to be_present
    end

    it 'is failure-tolerant and returns nil on error' do
      allow(Rails.logger).to receive(:warn)

      result = nil
      expect { result = described_class.record(account: nil, action_type: :suspend) }.to_not change(ModerationAction, :count)
      expect(result).to be_nil
    end
  end
end
