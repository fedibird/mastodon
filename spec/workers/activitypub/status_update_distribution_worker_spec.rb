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

  it 'does not deliver an Update when a new mention is the only reach on that server' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://only-mention.example/users/bob/inbox', shared_inbox_url: 'http://only-mention.example/inbox', domain: 'only-mention.example', username: 'bob')
    status.mentions.create!(account: introduced)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    inboxes = payloads.map { |row| row[2] }
    expect(inboxes).to include('http://example.com/inbox')
    expect(inboxes).not_to include(introduced.inbox_url)
    expect(inboxes).not_to include(introduced.shared_inbox_url)
  end

  it 'delivers an Update to a shared inbox that an existing follower still uses' do
    shared = 'http://server-x.example/inbox'
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://server-x.example/users/bob/inbox', shared_inbox_url: shared, domain: 'server-x.example', username: 'bob')
    follower_on_server = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://server-x.example/users/alice/inbox', shared_inbox_url: shared, domain: 'server-x.example', username: 'alice')
    status.mentions.create!(account: introduced)
    follower_on_server.follow!(status.account)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    delivered = payloads.select { |row| row[2] == shared }
    expect(delivered).not_to be_empty
    json = Oj.load(delivered.first.first)
    expect(json['type']).to eq 'Update'
    expect(json['object']['id']).to eq ActivityPub::TagManager.instance.uri_for(status)
    expect(payloads.map { |row| row[2] }).not_to include(introduced.inbox_url)
  end

  it 'delivers an Update when the new mention account is also an existing follower' do
    shared = 'http://follower-mention.example/inbox'
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://follower-mention.example/users/bob/inbox', shared_inbox_url: shared, domain: 'follower-mention.example', username: 'bob')
    status.mentions.create!(account: introduced)
    introduced.follow!(status.account)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(shared)
  end

  it 'delivers an Update when the new mention account is also an existing favouriter' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://self-favour.example/users/bob/inbox', shared_inbox_url: 'http://self-favour.example/inbox', domain: 'self-favour.example', username: 'bob')
    status.mentions.create!(account: introduced)
    Favourite.create!(account: introduced, status: status)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(introduced.shared_inbox_url)
  end

  it 'delivers an Update when the new mention account is also an existing reblogger' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://self-reblog.example/users/bob/inbox', shared_inbox_url: 'http://self-reblog.example/inbox', domain: 'self-reblog.example', username: 'bob')
    status.mentions.create!(account: introduced)
    Fabricate(:status, account: introduced, reblog: status, visibility: :public)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(introduced.shared_inbox_url)
  end

  it 'delivers an Update when the new mention account is also an existing replier' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://self-reply.example/users/bob/inbox', shared_inbox_url: 'http://self-reply.example/inbox', domain: 'self-reply.example', username: 'bob')
    status.mentions.create!(account: introduced)
    Fabricate(:status, account: introduced, thread: status, visibility: :public)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(introduced.shared_inbox_url)
  end

  it 'delivers an Update when the new mention account is the existing reply target' do
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://reply-target.example/users/bob/inbox', domain: 'reply-target.example', username: 'bob')
    parent = Fabricate(:status, account: introduced, visibility: :public)
    status.update!(in_reply_to_id: parent.id, in_reply_to_account_id: introduced.id)
    status.mentions.create!(account: introduced)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(introduced.inbox_url)
  end

  it 'delivers an Update to a shared inbox that an existing favouriter still uses' do
    shared = 'http://favour.example/inbox'
    introduced = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://favour.example/users/bob/inbox', shared_inbox_url: shared, domain: 'favour.example', username: 'bob')
    favouriter = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://favour.example/users/carol/inbox', shared_inbox_url: shared, domain: 'favour.example', username: 'carol')
    status.mentions.create!(account: introduced)
    Favourite.create!(account: favouriter, status: status)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(payloads.map { |row| row[2] }).to include(shared)
    expect(payloads.map { |row| row[2] }).not_to include(introduced.inbox_url)
  end

  it 'delegates a limited reply Update when the parent inbox matches the new mention shared inbox' do
    shared = 'https://parent.example/shared-inbox'
    conversation = Fabricate(:conversation, uri: 'https://parent.example/456', inbox_url: shared)
    parent_account = Fabricate(:account, protocol: :activitypub, username: 'parent2', domain: 'parent.example', inbox_url: 'https://parent.example/users/parent/inbox', shared_inbox_url: shared)
    parent = Fabricate(:status, visibility: :limited, account: parent_account, conversation: conversation)
    introduced = Fabricate(:account, protocol: :activitypub, username: 'bob', domain: 'parent.example', inbox_url: 'https://parent.example/users/bob/inbox', shared_inbox_url: shared)
    status.mentions.create!(account: introduced)
    status.update!(visibility: :limited, thread: parent, conversation: conversation)

    subject.perform(status.id, 'exclude_mentioned_account_ids' => [introduced.id])

    expect(ActivityPub::DeliveryWorker).to have_received(:perform_async).with(
      satisfy { |json| Oj.load(json)['type'] == 'Update' },
      status.account_id,
      shared
    )
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
