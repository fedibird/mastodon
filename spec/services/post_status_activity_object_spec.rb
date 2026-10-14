# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'status activity object guards', type: :service do
  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
    allow(LinkCrawlWorker).to receive(:perform_async)
  end

  it 'stores an internal note title and still serializes a Note' do
    account = Fabricate(:account)
    status = PostStatusService.new.call(account, text: 'body', post_title: '  日本語  ')

    expect(status).to be_persisted
    expect(status.post_title).to eq '日本語'
    expect(status[:ap_object_type]).to be_nil
    expect(status.ap_object_type).to eq 'note'

    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(status, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)
    expect(json['type']).to eq 'Note'
    expect(json).not_to have_key('name')
    expect(json['content']).to include('body')
    expect(json['content']).not_to include('日本語')
  end

  it 'refuses to create or schedule a page' do
    account = Fabricate(:account)

    expect do
      PostStatusService.new.call(account, text: 'body', post_title: 'Title', ap_object_type: 'page')
    end.to raise_error(Mastodon::ValidationError)

    expect do
      PostStatusService.new.call(account, text: 'later', post_title: 'Title', ap_object_type: 'page', scheduled_at: 10.minutes.from_now)
    end.to raise_error(Mastodon::ValidationError)

    expect(account.statuses).to be_empty
    expect(account.scheduled_statuses).to be_empty
    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
  end

  it 'refuses an unknown activity type' do
    account = Fabricate(:account)

    expect do
      PostStatusService.new.call(account, text: 'body', ap_object_type: 'Article')
    end.to raise_error(Mastodon::ValidationError)

    expect(account.statuses).to be_empty
  end

  it 'refuses a reply, quote, or boost of a page' do
    account = Fabricate(:account)
    page = Fabricate(:status, account: account, text: 'page body', post_title: 'Title', ap_object_type: 'page', visibility: :public)

    expect do
      PostStatusService.new.call(account, text: 'reply', thread: page)
    end.to raise_error(Mastodon::ValidationError)

    expect do
      PostStatusService.new.call(account, text: 'quote', quote_id: page.id)
    end.to raise_error(Mastodon::ValidationError)

    expect do
      ReblogService.new.call(account, page)
    end.to raise_error(Mastodon::ValidationError)

    expect(page.reblogs).to be_empty
  end

  it 'keeps poll and scheduled note creation available' do
    account = Fabricate(:account)
    poll = PostStatusService.new.call(account, text: 'vote', poll: { options: %w(Yes No), expires_in: 1.day.to_i })
    scheduled = PostStatusService.new.call(account, text: 'later', scheduled_at: 10.minutes.from_now)

    expect(poll.poll).to be_present
    expect(poll.ap_object_type).to eq 'note'
    expect(poll.post_title).to be_nil
    expect(scheduled).to be_a(ScheduledStatus)
    expect(scheduled.params).not_to have_key('post_title')
    expect(scheduled.params).not_to have_key('ap_object_type')
  end

  it 'does not change a note title from the edit service and does not edit a page' do
    account = Fabricate(:account)
    note = Fabricate(:status, account: account, text: 'original', post_title: 'Kept')
    page = Fabricate(:status, account: account, text: 'page body', post_title: 'Title', ap_object_type: 'page')

    UpdateStatusService.new.call(note, account.id, text: 'edited', post_title: 'Changed', ap_object_type: 'page')

    expect(note.reload.text).to eq 'edited'
    expect(note.post_title).to eq 'Kept'
    expect(note.ap_page?).to be false

    expect do
      UpdateStatusService.new.call(page, account.id, text: 'edited')
    end.to raise_error(Mastodon::ValidationError)

    expect(page.reload.text).to eq 'page body'
    expect(ActivityPub::StatusUpdateDistributionWorker).to have_received(:perform_async).once
  end

  it 'does not serialize or deliver a page as a Note' do
    account = Fabricate(:account)
    follower = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://example.com/inbox')
    follower.follow!(account)
    page = Fabricate(:status, account: account, text: 'page body', post_title: 'Title', ap_object_type: 'page', visibility: :public)

    expect do
      JSON.parse(ActiveModelSerializers::SerializableResource.new(page, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)
    end.to raise_error(Status::UnreleasedActivityObject)

    ActivityPub::DistributionWorker.new.perform(page.id)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)

    allow(FeedManager.instance).to receive(:push_to_home)
    FanOutOnWriteService.new.call(page)
    expect(FeedManager.instance).not_to have_received(:push_to_home)

    RemoveStatusService.new.call(page)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
    expect(page.discarded?).to be true
  end

  it 'still serializes a poll as a Question without a name' do
    account = Fabricate(:account)
    status = Fabricate(:status, account: account, text: 'vote')
    poll = Fabricate(:poll, account: account, status: status)
    status.update!(poll_id: poll.id)

    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(status.reload, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)
    expect(json['type']).to eq 'Question'
    expect(json).not_to have_key('name')
  end
end
# rubocop:enable Metrics/BlockLength
