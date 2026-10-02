# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublishStatusService, type: :service do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: account, text: 'hello') }

  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(PriorityDistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
  end

  it 'distributes, federates, and enqueues preview crawling once' do
    expect(LinkCrawlWorker).not_to receive(:new)

    subject.call(status)
    subject.call(status)

    expect(DistributionWorker).to have_received(:perform_async).with(status.id).once
    expect(PriorityDistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id).once
    expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id).once
    expect(status.preview_cards).to be_empty
  end

  it 'uses the priority distribution queue for a high priority author' do
    account.high_priority!

    subject.call(status)

    expect(PriorityDistributionWorker).to have_received(:perform_async).with(status.id)
    expect(DistributionWorker).not_to have_received(:perform_async)
  end

  it 'does not federate or deliver mentions for a personal status' do
    personal = Fabricate(:status, account: Fabricate(:user).account, visibility: :personal, text: 'Hello @alice')
    Fabricate(:account, username: 'alice')
    personal.mentions.create!(account: Account.find_by!(username: 'alice'))

    subject.call(personal)

    expect(DistributionWorker).to have_received(:perform_async).with(personal.id)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    expect(LocalNotificationWorker).not_to have_received(:perform_async)
  end

  it 'retries publish when federation enqueue fails before the completion marker' do
    calls = 0
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) do
      calls += 1
      raise Redis::CannotConnectError, 'down' if calls == 1
    end

    expect { subject.call(status) }.to raise_error(Redis::CannotConnectError)
    expect(subject.published?(status)).to be false
    expect(DistributionWorker).to have_received(:perform_async).with(status.id).once
    expect(LinkCrawlWorker).not_to have_received(:perform_async)

    subject.call(status)

    expect(subject.published?(status)).to be true
    expect(DistributionWorker).to have_received(:perform_async).with(status.id).twice
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id).twice
    expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id).once
  end

  it 'delivers explicit mentions from the persisted status' do
    alice = Fabricate(:account, username: 'alice')
    status.mentions.create!(account: alice)
    status.mentions.create!(account: Fabricate(:account, username: 'quiet'), silent: true)

    subject.call(status)

    expect(LocalNotificationWorker).to have_received(:perform_async).with(alice.id, status.mentions.find_by!(account: alice).id, 'Mention', 'mention')
    expect(LocalNotificationWorker).to have_received(:perform_async).once
  end
end
