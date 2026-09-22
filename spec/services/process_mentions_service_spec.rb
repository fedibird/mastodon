# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessMentionsService, type: :service do # rubocop:disable Metrics/BlockLength
  let(:account)    { Fabricate(:account, username: 'alice') }
  let(:visibility) { :public }
  let(:status)     { Fabricate(:status, account: account, text: "Hello @#{remote_user.acct}", visibility: visibility) }

  subject { ProcessMentionsService.new }

  context 'ActivityPub' do
    context do
      let(:remote_user) { Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox') }

      before do
        stub_request(:post, remote_user.inbox_url)
        subject.call(status)
      end

      it 'creates a mention' do
        expect(remote_user.mentions.where(status: status).count).to eq 1
      end

      it 'sends activity to the inbox' do
        expect(a_request(:post, remote_user.inbox_url)).to have_been_made.once
      end
    end

    context 'with an IDN domain' do
      let(:remote_user) { Fabricate(:account, username: 'sneak', protocol: :activitypub, domain: 'xn--hresiar-mxa.ch', inbox_url: 'http://example.com/inbox') }
      let(:status) { Fabricate(:status, account: account, text: 'Hello @sneak@hæresiar.ch') }

      before do
        stub_request(:post, remote_user.inbox_url)
        subject.call(status)
      end

      it 'creates a mention' do
        expect(remote_user.mentions.where(status: status).count).to eq 1
      end

      it 'sends activity to the inbox' do
        expect(a_request(:post, remote_user.inbox_url)).to have_been_made.once
      end
    end
  end

  context 'Temporarily-unreachable ActivityPub user' do
    let(:remote_user) { Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox', last_webfingered_at: nil) }

    before do
      stub_request(:get, 'https://example.com/.well-known/host-meta').to_return(status: 404)
      stub_request(:get, 'https://example.com/.well-known/webfinger?resource=acct:remote_user@example.com').to_return(status: 500)
      stub_request(:post, remote_user.inbox_url)
      subject.call(status)
    end

    it 'creates a mention' do
      expect(remote_user.mentions.where(status: status).count).to eq 1
    end

    it 'sends activity to the inbox' do
      expect(a_request(:post, remote_user.inbox_url)).to have_been_made.once
    end
  end

  context 'when editing' do
    let(:remote_user) { Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox') }
    let(:carol) { Fabricate(:account, username: 'carol_local') }
    let(:silent_account) { Fabricate(:account, username: 'silent') }

    before do
      stub_request(:post, remote_user.inbox_url)
      subject.call(status)
      status.mentions.create!(account: silent_account, silent: true)
      allow(LocalNotificationWorker).to receive(:perform_async)
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    end

    it 'reuses an existing mention, adds a new one, and keeps silent audience mentions' do
      status.update!(text: "Hello @#{remote_user.acct} @#{carol.username}")

      introduced = nil
      expect { introduced = subject.call(status, nil, edit: true) }.to change(ModerationInteractionEvent, :count).by(1)

      expect(remote_user.mentions.where(status: status).count).to eq 1
      expect(carol.mentions.where(status: status, silent: false).count).to eq 1
      expect(status.mentions.find_by(account: silent_account).silent).to be true
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)

      subject.deliver_mention_notifications(introduced)

      expect(LocalNotificationWorker).to have_received(:perform_async).with(carol.id, carol.mentions.find_by(status: status).id, 'Mention', 'mention')
      expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
    end

    it 'silences an explicit mention removed from the text without notifying the survivor again' do
      status.update!(text: "Hello @#{carol.username}")

      introduced = subject.call(status, nil, edit: true)
      subject.deliver_mention_notifications(introduced)

      expect(remote_user.mentions.find_by(status: status).silent).to be true
      expect(LocalNotificationWorker).to have_received(:perform_async).once
    end

    it 'does not notify or record moderation when the mentions are unchanged' do
      introduced = nil
      expect { introduced = subject.call(status, nil, edit: true) }.not_to change(ModerationInteractionEvent, :count)

      subject.deliver_mention_notifications(introduced)
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
    end

    it 'does not treat a silent mention becoming explicit as a new mention notification' do
      status.update!(text: "Hello @#{remote_user.acct} @#{silent_account.username}")
      mention = status.mentions.find_by(account: silent_account)

      introduced = subject.call(status, nil, edit: true)
      subject.deliver_mention_notifications(introduced)

      expect(mention.reload.silent).to be false
      expect(introduced.map(&:account_id)).not_to include(silent_account.id)
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
    end
  end
end
