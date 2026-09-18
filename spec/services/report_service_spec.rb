require 'rails_helper'

RSpec.describe ReportService, type: :service do
  subject { described_class.new }

  let(:source_account) { Fabricate(:user).account }

  context 'for a remote account' do
    let(:remote_account) { Fabricate(:account, domain: 'example.com', protocol: :activitypub, inbox_url: 'http://example.com/inbox') }

    before do
      stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
    end

    it 'sends ActivityPub payload when forward is true' do
      subject.call(source_account, remote_account, forward: true)
      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made
    end

    it 'does not send anything when forward is false' do
      subject.call(source_account, remote_account, forward: false)
      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
    end

    it 'has an uri' do
      report = subject.call(source_account, remote_account, forward: true)
      expect(report.uri).to_not be_nil
    end
  end

  context 'when other reports already exist for the same target' do
    let!(:target_account) { Fabricate(:account) }
    let!(:other_report)   { Fabricate(:report, target_account: target_account) }

    subject do
      -> {  described_class.new.call(source_account, target_account) }
    end

    before do
      ActionMailer::Base.deliveries.clear
      source_account.user.settings.notification_emails['report'] = true
    end

    it 'does not send an e-mail' do
      is_expected.to_not change(ActionMailer::Base.deliveries, :count).from(0)
    end
  end

  context 'with report categories' do
    let(:target_account) { Fabricate(:account) }

    it 'stores spam as spam' do
      report = subject.call(source_account, target_account, category: 'spam')

      expect(report).to be_spam
    end

    it 'stores legal as legal without rule ids' do
      report = subject.call(source_account, target_account, category: 'legal')

      expect(report).to be_legal
      expect(report.rule_ids).to be_blank
    end

    it 'forces rule ids to violation even when spam is requested' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      report = subject.call(source_account, target_account, category: 'spam', rule_ids: [rule.id])

      expect(report).to be_violation
      expect(report.rule_ids).to eq [rule.id]
    end

    it 'forces rule ids to violation even when legal is requested' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)
      report = subject.call(source_account, target_account, category: 'legal', rule_ids: [rule.id])

      expect(report).to be_violation
      expect(report).to_not be_legal
      expect(report.rule_ids).to eq [rule.id]
    end
  end
end
