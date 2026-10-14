# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'unreleased page visibility' do
  let(:author) { Fabricate(:account) }
  let(:note) { Fabricate(:status, account: author, text: 'visible note', visibility: :public) }
  let(:page) { Fabricate(:status, account: author, text: 'page body', visibility: :public, post_title: 'Title', ap_object_type: 'page') }

  it 'refuses the page in policy and search filtering without hiding the author note' do
    expect(StatusPolicy.new(author, page).show?).to be false
    expect(StatusPolicy.new(nil, page).show?).to be false
    expect(StatusPolicy.new(author, note).show?).to be true
    expect(StatusFilter.new(page, author).filtered?).to be true
    expect(StatusFilter.new(note, author).filtered?).to be false
  end

  it 'keeps the page out of account, public, and hashtag database reads' do
    Tag.find_or_create_by!(name: 'kept').statuses << note
    Tag.find_or_create_by!(name: 'kept').statuses << page

    expect(author.permitted_statuses(author)).to include(note)
    expect(author.permitted_statuses(author)).not_to include(page)
    expect(PublicFeed.new(nil).get(40).map(&:id)).to include(note.id)
    expect(PublicFeed.new(nil).get(40).map(&:id)).not_to include(page.id)
    expect(TagFeed.new(Tag.find_normalized('kept'), nil).get(40).map(&:id)).to include(note.id)
    expect(TagFeed.new(Tag.find_normalized('kept'), nil).get(40).map(&:id)).not_to include(page.id)
  end

  it 'does not hydrate a page id from a Redis timeline' do
    feed = HomeFeed.new(author)
    key = FeedManager.instance.key(:home, author.id)
    feed.redis.zadd(key, note.id, note.id)
    feed.redis.zadd(key, page.id, page.id)

    expect(feed.get(20).map(&:id)).to include(note.id)
    expect(feed.get(20).map(&:id)).not_to include(page.id)
  end

  it 'does not stream or webhook a page, and still does those for a note' do
    allow(TriggerWebhookWorker).to receive(:perform_async)
    published = []
    service = FanOutOnWriteService.new
    allow(service).to receive(:redis).and_wrap_original do |original|
      connection = original.call
      allow(connection).to receive(:publish).and_wrap_original do |publish, channel, payload|
        published << channel
        publish.call(channel, payload)
      end
      connection
    end

    service.call(page)
    expect(published).to be_empty

    service.call(note)
    expect(published).to include('timeline:public')
    expect(TriggerWebhookWorker).to have_received(:perform_async).with('status.created', 'Status', note.id)
    expect(TriggerWebhookWorker).not_to have_received(:perform_async).with('status.created', 'Status', page.id)
    expect(page.search_indexable?).to be false
    expect(note.search_indexable?).to be true
  end

  it 'drops a page from search results and Explore' do
    other = Fabricate(:account)
    visible = Fabricate(:status, account: other, text: 'trend note', visibility: :public)
    StatusTrend.create!(status: page, account: author, score: 10, rank: 1, allowed: true, language: 'en')
    StatusTrend.create!(status: visible, account: other, score: 9, rank: 2, allowed: true, language: 'en')

    ranked = Trends.statuses.query.allowed.limit(20).to_a
    expect(ranked).to include(visible)
    expect(ranked).not_to include(page)

    relation = double
    allow(relation).to receive(:collapse).and_return(relation)
    allow(relation).to receive(:limit).and_return(relation)
    allow(relation).to receive(:offset).and_return(relation)
    allow(relation).to receive(:pluck).and_return([page.id, note.id])
    service = StatusesSearchService.new
    allow(service).to receive(:parsed_query).and_return(double(request: relation))

    expect(service.call('visible', author, limit: 20, offset: 0)).to include(note)
    expect(service.call('visible', author, limit: 20, offset: 0)).not_to include(page)
  end

  it 'does not deliver create, update, or delete for a page' do
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    follower = Fabricate(:account, protocol: :activitypub, inbox_url: 'http://example.com/inbox')
    follower.follow!(author)

    ActivityPub::DistributionWorker.new.perform(page.id)
    ActivityPub::StatusUpdateDistributionWorker.new.perform(page.id)
    RemoveStatusService.new.call(page)

    expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
  end
end
# rubocop:enable Metrics/BlockLength
