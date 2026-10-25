# frozen_string_literal: true

# The examples share one fixture matrix.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'Feed icon scheduling' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml' }
  let(:icon_url) { 'https://cdn.example/feed.png' }
  let(:feed_body) do
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Example feed</title><link>https://feeds.example</link>
        <image><url>#{icon_url}</url></image>
        #{rss_item(guid: 'guid-1')}
      </channel></rss>
    XML
  end

  before do
    enable_external_bridge_rss!(user, other)
    redis.keys('external_bridge:rss*').each { |key| redis.del(key) }
    stub_request(:get, feed_url).to_return(status: 200, body: feed_body, headers: { 'ETag' => 'W/"one"' })
  end

  describe 'on subscribe' do
    it 'records the feed-declared candidates and queues one fetch for the new source' do
      subscription = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

      source = subscription.external_source.reload
      expect(source.icon_hints).to eq [{ 'kind' => 'rss_image', 'url' => icon_url }]
      expect(ExternalBridge::RSS::IconRefreshWorker).to have_received(:perform_async).with(source.id).once
    end

    it 'does not make the subscribe fail when the queue is unavailable' do
      allow(ExternalBridge::RSS::IconRefreshWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      expect { ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url) }.not_to raise_error
      expect(ExternalSubscription.where(user_id: user.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
    end

    it 'does not queue when the feature is off or the icon is not due' do
      source = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url).external_source
      source.update!(icon_next_check_at: 2.days.from_now)
      expect(ExternalBridge::RSS::Icon::Schedule.enqueue_if_due(source)).to be false
      Setting.external_bridge_rss = false
      source.update!(icon_next_check_at: nil)
      expect(ExternalBridge::RSS::Icon::Schedule.enqueue_if_due(source)).to be false
    end
  end

  describe 'end to end with the job running inline' do
    before do
      allow(ExternalBridge::RSS::IconRefreshWorker).to receive(:perform_async).and_call_original
      stub_icon(icon_url)
    end

    it 'fetches and stores once when two users subscribe to the same feed, and article delivery is unaffected' do
      first = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
      second = ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)

      source = first.external_source.reload
      expect(second.external_source_id).to eq source.id
      expect(source.icon).to be_present
      expect(a_request(:get, icon_url)).to have_been_made.once
      expect(ExternalStatusProjection.where(user_id: [user.id, other.id]).count).to eq 2
    end

    it 'keeps subscribing and projecting when the image is bad' do
      stub_icon(icon_url, bytes: 'not an image')
      stub_request(:get, 'https://feeds.example').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://feeds.example/favicon.ico').to_return(status: 404, body: 'no')

      subscription = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

      source = subscription.external_source.reload
      expect(source.icon).not_to be_present
      expect(source.icon_failure_count).to eq 1
      expect(subscription.state).to eq 'active'
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
    end

    it 'does not download again on later feed polls' do
      subscription = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
      subscription.update!(checked_at: 1.hour.ago, next_retry_at: nil)

      3.times { ExternalBridge::RSS::RefreshSource.new.call(subscription.external_source_id, subscription_id: subscription.id) }

      expect(a_request(:get, icon_url)).to have_been_made.once
    end
  end

  describe 'a changed declaration' do
    let(:source) { ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url).external_source.reload }

    it 'makes the icon due again, at most once an hour' do
      source.update!(icon_next_check_at: 3.days.from_now, icon_checked_at: 2.hours.ago)
      feed = ExternalBridge::RSS::Parser.parse!(feed_body.sub(icon_url, 'https://cdn.example/new.png'))

      ExternalBridge::RSS::Ingest.new.apply_public!(source, feed, ExternalBridge::RSS::Response.new(code: 200))
      expect(source.reload.icon_next_check_at).to be_nil
      expect(source.icon_hints.first['url']).to eq 'https://cdn.example/new.png'

      source.update!(icon_next_check_at: 3.days.from_now, icon_checked_at: 10.minutes.ago)
      changed = ExternalBridge::RSS::Parser.parse!(feed_body.sub(icon_url, 'https://cdn.example/newer.png'))
      ExternalBridge::RSS::Ingest.new.apply_public!(source.reload, changed, ExternalBridge::RSS::Response.new(code: 200))
      expect(source.reload.icon_next_check_at).to be > 2.days.from_now
      expect(source.icon_hints.first['url']).to eq 'https://cdn.example/newer.png'
    end

    it 'leaves the schedule alone when the declaration is unchanged' do
      source.update!(icon_next_check_at: 3.days.from_now)
      feed = ExternalBridge::RSS::Parser.parse!(feed_body)

      ExternalBridge::RSS::Ingest.new.apply_public!(source, feed, ExternalBridge::RSS::Response.new(code: 200))

      expect(source.reload.icon_next_check_at).to be > 2.days.from_now
    end
  end

  describe Scheduler::ExternalBridgeRSSIconScheduler do
    let(:scheduler) { described_class.new }

    def queued_ids
      ids = []
      allow(ExternalBridge::RSS::IconRefreshWorker).to receive(:perform_async) { |id| ids << id }
      scheduler.perform
      ids
    end

    it 'backfills an existing subscribed source that has never been checked' do
      source = icon_source(canonical_key: 'https://old.example/feed.xml', hints: nil)
      icon_subscriber(source, user)

      expect(queued_ids).to eq [source.id]
    end

    it 'skips sources that are not due, unsubscribed, paused, or never fetched, and users outside the tester list' do
      due = icon_source(canonical_key: 'https://a.example/feed.xml')
      icon_subscriber(due, user)
      not_due = icon_source(canonical_key: 'https://b.example/feed.xml', icon_next_check_at: 1.day.from_now)
      icon_subscriber(not_due, user)
      orphan = icon_source(canonical_key: 'https://c.example/feed.xml')
      paused = icon_source(canonical_key: 'https://d.example/feed.xml')
      ExternalSubscription.create!(user: user, external_source: paused, state: 'paused')
      unfetched = icon_source(canonical_key: 'https://e.example/feed.xml', fetched_at: nil)
      icon_subscriber(unfetched, user)
      outsider = icon_source(canonical_key: 'https://f.example/feed.xml')
      ExternalSubscription.create!(user: Fabricate(:user), external_source: outsider, state: 'active')

      expect(queued_ids).to eq [due.id]
      expect([orphan, paused, outsider].map(&:id)).not_to include(*queued_ids)
    end

    it 'picks up sources whose weekly re-check or backoff has arrived' do
      due = icon_source(canonical_key: 'https://a.example/feed.xml', icon_next_check_at: 1.minute.ago)
      icon_subscriber(due, user)

      expect(queued_ids).to eq [due.id]
    end

    it 'queues a bounded batch, oldest first' do
      sources = Array.new(described_class::BATCH + 5) do |index|
        icon_source(canonical_key: "https://s#{index}.example/feed.xml", icon_next_check_at: (index + 1).hours.ago).tap { |source| icon_subscriber(source, user) }
      end

      ids = queued_ids

      expect(ids.size).to eq described_class::BATCH
      expect(ids.first).to eq sources.last.id
    end

    it 'does nothing when the feature is off' do
      source = icon_source(canonical_key: 'https://old.example/feed.xml')
      icon_subscriber(source, user)
      Setting.external_bridge_rss = false

      expect(queued_ids).to eq []
    end
  end

  describe ExternalBridge::RSS::IconRefreshWorker do
    it 'is a no-op for a source deleted before the job ran' do
      allow(described_class).to receive(:perform_async).and_call_original
      expect { described_class.perform_async(0) }.not_to raise_error
    end
  end

  describe ExternalBridge::RSS::CanonicalURL do
    it 'keeps cache-busting queries only for asset URLs' do
      expect(described_class.normalize!('https://cdn.example/i.png?v=3&w=64', asset: true)).to eq 'https://cdn.example/i.png?v=3&w=64'
      expect { described_class.normalize!('https://cdn.example/i.png?v=3') }.to raise_error(ExternalBridge::Error)
    end

    it 'still rejects credentials, long values and unknown names for assets' do
      [
        'https://cdn.example/i.png?token=abc',
        "https://cdn.example/i.png?v=#{'a' * 33}",
        'https://cdn.example/i.png?v=1&v=2&v=3&v=4',
        'https://cdn.example/i.png?v=%2e%2e%2f',
        'https://cdn.example/i.png?v=',
        'https://cdn.example/i.png?',
        'https://cdn.example/i.png?v=1&sig=x',
        'https://u:p@cdn.example/i.png',
      ].each do |url|
        expect { described_class.normalize!(url, asset: true) }.to raise_error(ExternalBridge::Error), "expected #{url} to be rejected"
      end
    end
  end
end
