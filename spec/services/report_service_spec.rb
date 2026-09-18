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
      report = subject.call(source_account, remote_account, forward: true)

      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
      expect(report.forwarded).to be true
    end

    it 'does not send anything when forward is false' do
      report = subject.call(source_account, remote_account, forward: false)

      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be false
    end

    it 'has an uri' do
      report = subject.call(source_account, remote_account, forward: true)
      expect(report.uri).to_not be_nil
    end
  end

  context 'when forwarding to selected domains' do
    let(:remote_account) { Fabricate(:account, domain: 'example.com', protocol: :activitypub, inbox_url: 'http://example.com/inbox') }
    let(:remote_thread_account) { Fabricate(:account, domain: 'foo.com', protocol: :activitypub, inbox_url: 'http://foo.com/inbox') }
    let(:reported_status) { Fabricate(:status, account: remote_account, thread: Fabricate(:status, account: remote_thread_account)) }

    before do
      stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
      stub_request(:post, 'http://foo.com/inbox').to_return(status: 200)
      stub_request(:post, 'http://evil.example/inbox').to_return(status: 200)
      expect(reported_status.in_reply_to_account_id).to eq remote_thread_account.id
    end

    it 'does not forward a reply to the replied-to server when forward_to_domains is omitted' do
      report = subject.call(source_account, remote_account, status_ids: [reported_status.id], forward: true)

      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
      expect(a_request(:post, 'http://foo.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be true
    end

    it 'forwards to both origin and replied-to servers when both domains are selected' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: [remote_account.domain, remote_thread_account.domain]
      )

      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
      expect(a_request(:post, 'http://foo.com/inbox')).to have_been_made.once
      expect(report.forwarded).to be true
    end

    it 'forwards only to the replied-to server when origin is omitted' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: [remote_thread_account.domain]
      )

      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://foo.com/inbox')).to have_been_made.once
      expect(report.forwarded).to be false
    end

    it 'forwards only to the origin when only the reported account domain is selected' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: [remote_account.domain]
      )

      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
      expect(a_request(:post, 'http://foo.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be true
    end

    it 'does not forward when forward is false even if domains are listed' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: false,
        forward_to_domains: [remote_account.domain, remote_thread_account.domain]
      )

      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://foo.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be false
    end

    it 'does not forward when forward_to_domains is an empty array' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: []
      )

      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://foo.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be false
    end

    it 'does not forward to an unrelated domain' do
      Fabricate(:account, domain: 'evil.example', protocol: :activitypub, inbox_url: 'http://evil.example/inbox')

      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: ['evil.example']
      )

      expect(a_request(:post, 'http://evil.example/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://foo.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be false
    end

    it 'normalizes and deduplicates selected domains' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: [' FOO.COM/ ', 'foo.com']
      )

      expect(a_request(:post, 'http://foo.com/inbox')).to have_been_made.once
      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be false
    end
  end

  context 'when the replied-to account is on the same server' do
    let(:remote_account) do
      Fabricate(
        :account,
        domain: 'example.com',
        protocol: :activitypub,
        inbox_url: 'http://example.com/users/alice/inbox',
        shared_inbox_url: 'http://example.com/inbox'
      )
    end
    let(:remote_thread_account) do
      Fabricate(
        :account,
        domain: 'example.com',
        protocol: :activitypub,
        inbox_url: 'http://example.com/users/bob/inbox',
        shared_inbox_url: 'http://example.com/inbox'
      )
    end
    let(:reported_status) { Fabricate(:status, account: remote_account, thread: Fabricate(:status, account: remote_thread_account)) }

    before do
      stub_request(:post, 'http://example.com/users/alice/inbox').to_return(status: 200)
      stub_request(:post, 'http://example.com/users/bob/inbox').to_return(status: 200)
      stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
    end

    it 'sends only one ActivityPub report to that server' do
      report = subject.call(
        source_account,
        remote_account,
        status_ids: [reported_status.id],
        forward: true,
        forward_to_domains: ['example.com']
      )

      expect(a_request(:post, 'http://example.com/users/alice/inbox')).to have_been_made.once
      expect(a_request(:post, 'http://example.com/users/bob/inbox')).to_not have_been_made
      expect(a_request(:post, 'http://example.com/inbox')).to_not have_been_made
      expect(report.forwarded).to be true
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
