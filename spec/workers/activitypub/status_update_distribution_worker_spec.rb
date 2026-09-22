# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::StatusUpdateDistributionWorker do # rubocop:disable Metrics/BlockLength
  subject { described_class.new }

  let(:status) { Fabricate(:status, text: 'edited body', visibility: :public) }
  let(:follower) { Fabricate(:account, protocol: :activitypub, inbox_url: 'http://example.com/inbox') }
  let(:payloads) { [] }

  before do
    status.update!(edited_at: Time.utc(2026, 9, 22, 12, 0, 0))
    follower.follow!(status.account)
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) do |inboxes, &block|
      inboxes.each { |inbox| payloads << block.call(inbox) }
    end
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
  end

  it 'delivers an Update activity whose object keeps quote extensions' do
    quoted = Fabricate(:status, visibility: :public, text: 'quoted')
    status.update!(quote_id: quoted.id, edited_at: Time.utc(2026, 9, 22, 12, 0, 0))

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['http://example.com/inbox'])
    json = Oj.load(payloads.first.first)
    expect(json['type']).to eq 'Update'
    expect(json['id']).to eq "#{ActivityPub::TagManager.instance.uri_for(status)}#updates/#{status.edited_at.to_i}"
    expect(json['published']).to eq status.edited_at.iso8601
    expect(json['object']['updated']).to eq status.edited_at.iso8601
    expect(json['object']['quoteUri']).to eq ActivityPub::TagManager.instance.uri_for(quoted)
  end

  it 'does not deliver a personal status' do
    status.update!(visibility: :personal)

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end

  it 'delivers an Update to a mentioned remote account who does not follow' do
    mentioned = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://mentioned.example/inbox', domain: 'mentioned.example', username: 'mentioned')
    status.mentions.create!(account: mentioned)

    subject.perform(status.id)

    expect(payloads.map { |row| row[2] }).to include('http://mentioned.example/inbox')
    json = Oj.load(payloads.find { |row| row[2] == 'http://mentioned.example/inbox' }.first)
    expect(json['type']).to eq 'Update'
  end

  it 'delivers an Update to a remote favouriter' do
    favouriter = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://favouriter.example/inbox', domain: 'favouriter.example', username: 'favouriter')
    Favourite.create!(account: favouriter, status: status)

    subject.perform(status.id)

    expect(payloads.map { |row| row[2] }).to include('http://favouriter.example/inbox')
  end

  it 'delivers a direct Update to the existing remote mention and not to an unrelated follower' do
    mentioned = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://direct-mention.example/inbox', domain: 'direct-mention.example', username: 'directmention')
    status.update!(visibility: :direct)
    status.mentions.create!(account: mentioned)

    subject.perform(status.id)

    inboxes = payloads.map { |row| row[2] }
    expect(inboxes).to include('http://direct-mention.example/inbox')
    expect(inboxes).not_to include('http://example.com/inbox')
    expect(Oj.load(payloads.find { |row| row[2] == 'http://direct-mention.example/inbox' }.first)['type']).to eq 'Update'
  end

  it 'does not deliver a limited status to an unrelated follower' do
    mentioned = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://limited-mention.example/inbox', domain: 'limited-mention.example', username: 'limitedmention')
    status.update!(visibility: :limited)
    status.mentions.create!(account: mentioned, silent: true)

    subject.perform(status.id)

    inboxes = payloads.map { |row| row[2] }
    expect(inboxes).to include('http://limited-mention.example/inbox')
    expect(inboxes).not_to include('http://example.com/inbox')
  end

  it 'omits inboxes that already received a Create for a newly introduced mention' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://mentioned.example/users/mentioned/inbox', shared_inbox_url: 'http://mentioned.example/inbox', domain: 'mentioned.example', username: 'mentioned')
    other = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://other.example/inbox', domain: 'other.example', username: 'otherfan')
    status.mentions.create!(account: introduced)
    other.follow!(status.account)

    subject.perform(status.id, 'exclude_inboxes' => [introduced.inbox_url, introduced.shared_inbox_url])

    inboxes = payloads.map { |row| row[2] }
    expect(inboxes).to include('http://example.com/inbox')
    expect(inboxes).to include('http://other.example/inbox')
    expect(inboxes).not_to include(introduced.inbox_url)
    expect(inboxes).not_to include(introduced.shared_inbox_url)
  end

  it 'does not delegate an Update to an inbox excluded for this edit' do
    conversation = Fabricate(:conversation, uri: 'https://parent.example/456', inbox_url: 'https://parent.example/inbox')
    parent = Fabricate(:status, visibility: :limited, account: Fabricate(:account, protocol: :activitypub, username: 'parent2', domain: 'parent.example', inbox_url: 'https://parent.example/users/inbox'), conversation: conversation)
    status.update!(visibility: :limited, thread: parent, conversation: conversation)

    subject.perform(status.id, 'exclude_inboxes' => ['https://parent.example/inbox'])

    expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end

  it 'delegates a limited reply to the remote parent inbox' do
    conversation = Fabricate(:conversation, uri: 'https://parent.example/123', inbox_url: 'https://parent.example/inbox')
    parent = Fabricate(:status, visibility: :limited, account: Fabricate(:account, protocol: :activitypub, username: 'parent', domain: 'parent.example', inbox_url: 'https://parent.example/users/inbox'), conversation: conversation)
    status.update!(visibility: :limited, thread: parent, conversation: conversation)

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:perform_async).with(anything, status.account_id, 'https://parent.example/inbox')
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
  end
end
