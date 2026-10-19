# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Subscribe do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml' }

  before { enable_external_bridge_rss! }

  describe 'shared public cache' do
    let(:body) do
      rss_document(
        rss_item(guid: 'guid-1', body: 'Shared public article') +
        rss_item(guid: 'guid-2', title: 'Second', link: 'https://example.com/second', body: 'Another')
      )
    end

    before do
      stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => 'W/"one"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' })
    end

    it 'stores one resource and two owner-private statuses' do
      first = described_class.new.call(user: user, url: feed_url)
      second = described_class.new.call(user: other, url: feed_url)

      expect(ExternalSource.where(canonical_key: feed_url).count).to eq 1
      expect(ExternalResource.where(external_source_id: first.external_source_id).count).to eq 2
      expect(ExternalResource.column_names).not_to include('user_id')
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 2
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 2
      expect(ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)).not_to match_array(
        ExternalStatusProjection.where(user_id: other.id).pluck(:status_id)
      )
      expect(Account.where(domain: 'example.com')).to be_empty

      owner_status = Status.find(ExternalStatusProjection.find_by(user_id: user.id).status_id)
      FavouriteService.new.call(user.account, owner_status, viewer_user: user)
      expect(Favourite.where(account: other.account, status: owner_status)).not_to exist
      expect(other.account.bookmarks.where(status: owner_status)).not_to exist
    end

    it 'is idempotent for the same guid and skips an item with neither guid nor link' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(
          rss_item(guid: 'guid-1') +
          '<item><title>No identity</title><description>skip me</description></item>' +
          rss_item(guid: 'guid-1', title: 'Same guid again')
        )
      )

      described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: user, url: feed_url)

      source = ExternalSource.find_by!(canonical_key: feed_url)
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
      expect(source.external_resources.count).to eq 1
    end

    it 'keeps distinct resources when the title matches and the guid does not' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(
          rss_item(guid: 'a', title: 'Same') +
          rss_item(guid: 'b', title: 'Same', link: 'https://example.com/b')
        )
      )

      described_class.new.call(user: user, url: feed_url)
      expect(ExternalSource.find_by!(canonical_key: feed_url).external_resources.count).to eq 2
    end

    it 'stores a nil publication time for a malformed date and still projects the item' do
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'dated', date: 'not-a-date')))

      described_class.new.call(user: user, url: feed_url)
      resources = ExternalSource.find_by!(canonical_key: feed_url).external_resources.to_a
      expect(resources.size).to eq 1
      expect(resources.first.published_at).to be_nil
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
    end
  end

  describe 'private and unsafe responses' do
    it 'rejects a literal private address and a token or userinfo URL without a shared row' do
      sources_before = ExternalSource.count
      resources_before = ExternalResource.count

      expect { described_class.new.call(user: user, url: 'http://127.0.0.1/feed.xml') }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'private_address' }
      expect { described_class.new.call(user: user, url: 'http://169.254.169.254/latest') }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'private_address' }
      expect { described_class.new.call(user: user, url: 'https://user:secret@feeds.example/feed.xml') }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
      expect { described_class.new.call(user: user, url: 'https://feeds.example/feed.xml?token=secret') }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }

      expect(ExternalSource.count).to eq sources_before
      expect(ExternalResource.count).to eq resources_before
      expect(ExternalSource.where("canonical_key LIKE '%secret%'").count).to eq 0
    end

    it 'does not create a shared row for 401 or a redirect onto a private address' do
      stub_request(:get, 'https://feeds.example/private.xml').to_return(status: 401, body: 'no')
      stub_request(:get, 'https://feeds.example/bounce.xml').to_return(status: 302, headers: { 'Location' => 'http://127.0.0.1/secret' })
      stub_request(:get, 'http://127.0.0.1/secret').to_return(status: 200, body: rss_document(rss_item(guid: 'leaked')))
      sources_before = ExternalSource.count
      resources_before = ExternalResource.count

      expect { described_class.new.call(user: user, url: 'https://feeds.example/private.xml') }
        .to raise_error(ExternalBridge::Error)
      expect { described_class.new.call(user: other, url: 'https://feeds.example/private.xml') }
        .to raise_error(ExternalBridge::Error)
      expect { described_class.new.call(user: user, url: 'https://feeds.example/bounce.xml') }
        .to raise_error(ExternalBridge::Error)

      expect(ExternalSource.count).to eq sources_before
      expect(ExternalResource.count).to eq resources_before
      expect(ExternalSource.where(canonical_key: ['https://feeds.example/private.xml', 'https://feeds.example/bounce.xml'])).to be_empty
      expect(a_request(:get, 'http://127.0.0.1/secret')).not_to have_been_made
    end

    it 'leaves the shared etag and body unchanged when a public feed later returns 401' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'guid-1', body: 'Public copy')),
        headers: { 'ETag' => 'W/"one"' }
      )
      described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: other, url: feed_url)
      source = ExternalSource.find_by!(canonical_key: feed_url)
      source.update!(fetched_at: 1.hour.ago)
      resource = source.external_resources.first

      stub_request(:get, feed_url).to_return(status: 401, body: 'gone', headers: { 'ETag' => 'W/"private"' })
      expect { described_class.new.call(user: user, url: feed_url) }.to raise_error(ExternalBridge::Error)

      expect(source.reload.etag).to eq 'W/"one"'
      expect(resource.reload.body).to eq 'Public copy'
      expect(ExternalSubscription.find_by!(user: user, external_source: source).state).to eq 'error'
      expect(ExternalSubscription.find_by!(user: other, external_source: source).state).to eq 'active'
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 1
    end

    it 'reuses a verified public cache on 304 and ignores the failed response headers' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'guid-1')),
        headers: { 'ETag' => 'W/"one"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' }
      )
      described_class.new.call(user: user, url: feed_url)
      source = ExternalSource.find_by!(canonical_key: feed_url)
      source.update!(fetched_at: 1.hour.ago)

      stub_request(:get, feed_url).to_return(status: 304, headers: { 'ETag' => 'W/"ignored"' })
      described_class.new.call(user: other, url: feed_url)

      expect(source.reload.etag).to eq 'W/"one"'
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 1
      expect(ExternalResource.where(external_source_id: source.id).count).to eq 1
    end
  end

  describe 'XML safety' do
    it 'does not fetch an external entity' do
      xml = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss [ <!ENTITY xxe SYSTEM "http://127.0.0.1/xxe-secret"> ]>
        <rss version="2.0"><channel><title>&xxe;</title><link>https://example.com</link>
          <item><guid>g</guid><title>t</title><link>https://example.com/a</link><description>body</description></item>
        </channel></rss>
      XML
      stub_request(:get, 'http://127.0.0.1/xxe-secret').to_return(status: 200, body: 'SECRET')
      stub_request(:get, feed_url).to_return(status: 200, body: xml)

      described_class.new.call(user: user, url: feed_url)

      expect(a_request(:get, 'http://127.0.0.1/xxe-secret')).not_to have_been_made
      expect(ExternalSource.find_by!(canonical_key: feed_url).title.to_s).not_to include('SECRET')
    end

    it 'rejects malformed XML and does not keep a shared row from it' do
      stub_request(:get, feed_url).to_return(status: 200, body: '<rss>')

      expect { described_class.new.call(user: user, url: feed_url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }
      expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
    end

    it 'strips markup instead of storing it as HTML' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'html', body: '<script>alert(1)</script><b>Visible</b> #tag @alice'))
      )

      described_class.new.call(user: user, url: feed_url)
      status = Status.find(ExternalStatusProjection.last.status_id)
      expect(status.text).to include('Visible')
      expect(status.text).not_to include('<script>')
      expect(status.tags).to be_empty
      expect(status.mentions).to be_empty
      expect(status.preview_cards).to be_empty
    end
  end

  describe 'feature flag and bounds' do
    it 'does not fetch or write when the flag is off' do
      Setting.external_bridge_rss = false
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'g')))

      sources_before = ExternalSource.count
      expect { described_class.new.call(user: user, url: feed_url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'feature_disabled' }
      ExternalBridge::RSS::RefreshSourceWorker.new.perform(1)
      expect(ExternalSource.count).to eq sources_before
      expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
      expect(a_request(:get, feed_url)).not_to have_been_made
    end

    it 'does not enqueue a refresh while the flag is off' do
      Setting.external_bridge_rss = false
      expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)
      Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
    end

    it 'skips a refresh while another worker holds the source lock' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, title: 'Held', fetched_at: 1.hour.ago, checked_at: 1.hour.ago)
      ExternalSubscription.create!(user: user, external_source: source, state: 'active')
      # Same-session advisory locks are re-entrant, so the holder has to be another connection.
      holder = nil
      holder = ActiveRecord::Base.connection_pool.checkout
      locked = holder.select_value("SELECT pg_try_advisory_lock(810531, #{source.id.to_i})")
      expect(locked == true || locked.to_s == 't').to be true
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'g')))

      ExternalBridge::RSS::RefreshSource.new.call(source.id)
      expect(source.reload.title).to eq 'Held'
      expect(a_request(:get, feed_url)).not_to have_been_made
    ensure
      if holder
        holder.select_value("SELECT pg_advisory_unlock(810531, #{source.id.to_i})") if source&.id
        ActiveRecord::Base.connection_pool.checkin(holder)
      end
    end

    it 'does not log a token when a fetch fails' do
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message.to_s }
      allow(ExternalBridge::RSS::HttpClient).to receive(:get).and_raise(ExternalBridge::Error, :fetch_failed)
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/news.xml?ignored=1')
      ExternalSubscription.create!(user: user, external_source: source)

      ExternalBridge::RSS::RefreshSource.new.call(source.id)

      logged = messages.join("\n")
      expect(logged).to include("host_key=#{source.id}")
      expect(logged).to include('code=fetch_failed')
      expect(logged).not_to include(source.canonical_key)
      expect(logged).not_to include('encrypted_payload')
    end
  end

  describe 'link preview' do
    it 'does not crawl a URL stored on a projection' do
      bundle = project_for(user, body: "See https://example.com/article")
      expect(LinkCrawlWorker).not_to receive(:perform_async)
      FetchLinkCardService.new.call(bundle[:status])
      LinkCrawlWorker.new.perform(bundle[:status].id)
      expect(bundle[:status].preview_cards.reload).to be_empty
    end
  end
end
