require 'rails_helper'

describe Report do
  describe 'statuses' do
    it 'returns the statuses for the report' do
      status = Fabricate(:status)
      _other = Fabricate(:status)
      report = Fabricate(:report, status_ids: [status.id])

      expect(report.statuses).to eq [status]
    end
  end

  describe 'media_attachments_count' do
    it 'returns count of media attachments in statuses' do
      status1 = Fabricate(:status, ordered_media_attachment_ids: [1, 2])
      status2 = Fabricate(:status, ordered_media_attachment_ids: [5])
      report  = Fabricate(:report, status_ids: [status1.id, status2.id])

      expect(report.media_attachments_count).to eq 3
    end
  end

  describe 'assign_to_self!' do
    subject { report.assigned_account_id }

    let(:report) { Fabricate(:report, assigned_account_id: original_account) }
    let(:original_account) { Fabricate(:account) }
    let(:current_account) { Fabricate(:account) }

    before do
      report.assign_to_self!(current_account)
    end

    it 'assigns to a given account' do
      is_expected.to eq current_account.id
    end
  end

  describe 'unassign!' do
    subject { report.assigned_account_id }

    let(:report) { Fabricate(:report, assigned_account_id: account.id) }
    let(:account) { Fabricate(:account) }

    before do
      report.unassign!
    end

    it 'unassigns' do
      is_expected.to be_nil
    end
  end

  describe 'resolve!' do
    subject(:report) { Fabricate(:report, action_taken_at: nil, action_taken_by_account_id: nil) }

    let(:acting_account) { Fabricate(:account) }

    it 'records action taken as a timestamp' do
      freeze_time do
        report.resolve!(acting_account)

        expect(report.action_taken_at).to eq Time.now.utc
        expect(report.action_taken_by_account_id).to eq acting_account.id
        expect(report).to be_action_taken
        expect(report.action_taken).to be true
        expect(report).to_not be_unresolved
      end
    end

    it 'restores trust level for automated anti-spam false positives' do
      target = Fabricate(:account, trust_level: Account::TRUST_LEVELS[:untrusted])
      report = Fabricate(:report, account: Account.representative, target_account: target)

      report.resolve!(acting_account)

      expect(target.reload.trust_level).to eq Account::TRUST_LEVELS[:trusted]
    end

    it 'enqueues RemovalWorker for discarded statuses' do
      status = Fabricate(:status)
      status.discard
      report = Fabricate(:report, status_ids: [status.id])
      allow(RemovalWorker).to receive(:push_bulk)

      report.resolve!(acting_account)

      expect(RemovalWorker).to have_received(:push_bulk).with([status.id])
    end
  end

  describe 'unresolve!' do
    subject(:report) { Fabricate(:report, action_taken_at: Time.now.utc, action_taken_by_account_id: acting_account.id) }

    let(:acting_account) { Fabricate(:account) }

    before do
      report.unresolve!
    end

    it 'clears the resolution timestamp' do
      expect(report.action_taken_at).to be_nil
      expect(report.action_taken_by_account_id).to be_nil
      expect(report).to_not be_action_taken
      expect(report.action_taken).to be false
    end
  end

  describe 'action_taken?' do
    it 'is false when action_taken_at is nil' do
      report = Fabricate(:report, action_taken_at: nil)

      expect(report.action_taken_at).to be_nil
      expect(report).to_not be_action_taken
      expect(report).to be_unresolved
    end

    it 'is true when action_taken_at is present' do
      report = Fabricate(:report, action_taken_at: Time.now.utc)

      expect(report.action_taken_at).to be_present
      expect(report).to be_action_taken
      expect(report).to_not be_unresolved
    end
  end

  describe 'unresolved?' do
    subject { report.unresolved? }

    let(:report) { Fabricate(:report, action_taken_at: action_taken_at) }

    context 'if action is taken' do
      let(:action_taken_at) { Time.now.utc }

      it { is_expected.to be false }
    end

    context 'if action not is taken' do
      let(:action_taken_at) { nil }

      it { is_expected.to be true }
    end
  end

  describe 'scopes' do
    let!(:unresolved_report) { Fabricate(:report, action_taken_at: nil) }
    let!(:resolved_report) { Fabricate(:report, action_taken_at: Time.now.utc) }

    it 'returns only unresolved reports' do
      expect(described_class.unresolved).to contain_exactly(unresolved_report)
    end

    it 'returns only resolved reports' do
      expect(described_class.resolved).to contain_exactly(resolved_report)
    end
  end

  describe 'history' do
    subject(:action_logs) { report.history }

    let(:report) { Fabricate(:report, target_account_id: target_account.id, status_ids: [status.id], created_at: 3.days.ago, updated_at: 1.day.ago) }
    let(:target_account) { Fabricate(:account) }
    let(:status) { Fabricate(:status) }

    before do
      Fabricate('Admin::ActionLog', target_type: 'Report', account_id: target_account.id, target_id: report.id, created_at: 2.days.ago)
      Fabricate('Admin::ActionLog', target_type: 'Account', account_id: target_account.id, target_id: report.target_account_id, created_at: 2.days.ago)
      Fabricate('Admin::ActionLog', target_type: 'Status', account_id: target_account.id, target_id: status.id, created_at: 2.days.ago)
    end

    it 'returns right logs' do
      expect(action_logs.count).to eq 3
    end
  end

  describe 'validatiions' do
    it 'has a valid fabricator' do
      report = Fabricate(:report)
      report.valid?
      expect(report).to be_valid
    end

    it 'is invalid if comment is longer than 1000 characters' do
      report = Fabricate.build(:report, comment: Faker::Lorem.characters(number: 1001))
      report.valid?
      expect(report).to model_have_error_on_field(:comment)
    end

    it 'is valid as a violation with an existing rule' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      report = Fabricate.build(:report, category: :violation, rule_ids: [rule.id])

      expect(report).to be_valid
    end

    it 'is invalid as a violation with an unknown rule' do
      report = Fabricate.build(:report, category: :violation, rule_ids: [-1])
      report.valid?

      expect(report).to model_have_error_on_field(:rule_ids)
    end

    it 'is invalid as a violation without rules' do
      report = Fabricate.build(:report, category: :violation, rule_ids: nil)
      report.valid?

      expect(report).to model_have_error_on_field(:rule_ids)
    end

    it 'is invalid when a non-violation category includes rule_ids' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      report = Fabricate.build(:report, category: :spam, rule_ids: [rule.id])
      report.valid?

      expect(report).to model_have_error_on_field(:rule_ids)
    end

    it 'is valid as legal without rule ids' do
      report = Fabricate.build(:report, category: :legal, rule_ids: nil)

      expect(report).to be_valid
      expect(report).to be_legal
    end

    it 'is invalid as legal with rule ids' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      report = Fabricate.build(:report, category: :legal, rule_ids: [rule.id])
      report.valid?

      expect(report).to_not be_valid
      expect(report).to model_have_error_on_field(:rule_ids)
    end

    it 'is valid as a violation with a discarded rule' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      rule.discard
      report = Fabricate.build(:report, category: :violation, rule_ids: [rule.id])

      expect(report).to be_valid
    end
  end
end
