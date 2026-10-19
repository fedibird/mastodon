# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Subscribe do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml' }

  before do
    enable_external_bridge_rss!(user, other)
    redis.keys('external_bridge:rss:host:*').each { |key| redis.del(key) }
  end

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

  describe 'credential-like queries' do
    it 'rejects unknown, aliased, and deeply encoded query names before a request or a shared row' do
      encoded_auth = "#{'%25' * 6}61uth_token"
      urls = [
        'https://feeds.example/rss?%74oken=SECRET',
        'https://feeds.example/rss?%2574oken=SECRET',
        'https://feeds.example/rss?API_KEY=SECRET',
        'https://feeds.example/rss?password=SECRET',
        'https://feeds.example/rss?auth=SECRET',
        'https://feeds.example/rss?auth_token=SECRET',
        'https://feeds.example/rss?api_token=SECRET',
        'https://feeds.example/rss?secret_key=SECRET',
        'https://feeds.example/rss?access_key=SECRET',
        'https://feeds.example/rss?feed_token=SECRET',
        'https://feeds.example/rss?mystery=SECRET',
        'https://feeds.example/rss?Token=SECRET',
        'https://feeds.example/rss?access-token=SECRET',
        'https://feeds.example/rss?a=1&token=SECRET&a=2',
        'https://feeds.example/rss?token[]=SECRET',
        'https://feeds.example/rss?format=rss&auth_token=SECRET',
        'https://feeds.example/rss?q=%',
        'https://feeds.example/rss?q=%ZZ',
        "https://feeds.example/rss?#{encoded_auth}=SECRET",
      ]
      sources_before = ExternalSource.count

      urls.each do |url|
        expect { described_class.new.call(user: user, url: url) }
          .to raise_error(ExternalBridge::Error) { |error| expect(%w(authenticated_source_rejected unsupported_url)).to include(error.code) }
      end

      expect(ExternalSource.count).to eq sources_before
      expect(ExternalSource.where("canonical_key ILIKE '%secret%'")).to be_empty
      expect(a_request(:get, /SECRET/)).not_to have_been_made
    end

    it 'accepts a public format query and rejects a redirect onto a token query before that hop' do
      public_url = 'https://feeds.example/listed.xml?format=rss'
      stub_request(:get, public_url).to_return(status: 200, body: rss_document(rss_item(guid: 'listed')))
      described_class.new.call(user: user, url: 'https://feeds.example/listed.xml?FORMAT=RSS')
      expect(ExternalSource.find_by!(canonical_key: public_url)).to be_present

      encoded = 'https://feeds.example/encoded.xml?%2566ormat=%2572ss'
      normalized = 'https://feeds.example/encoded.xml?format=rss'
      stub_request(:get, normalized).to_return(status: 200, body: rss_document(rss_item(guid: 'encoded')))
      described_class.new.call(user: user, url: encoded)
      expect(ExternalSource.find_by!(canonical_key: normalized)).to be_present
      expect(a_request(:get, encoded)).not_to have_been_made

      stub_request(:get, 'https://feeds.example/jump.xml').to_return(status: 302, headers: { 'Location' => 'https://feeds.example/hidden.xml?auth_token=SECRET' })
      stub_request(:get, 'https://feeds.example/hidden.xml?auth_token=SECRET').to_return(status: 200, body: rss_document(rss_item(guid: 'hidden')))
      expect { described_class.new.call(user: user, url: 'https://feeds.example/jump.xml') }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
      expect(a_request(:get, 'https://feeds.example/hidden.xml?auth_token=SECRET')).not_to have_been_made
      expect(ExternalSource.where("canonical_key ILIKE '%secret%'")).to be_empty
    end
  end

  describe 'status excerpt' do
    def expect_status_length(status)
      StatusLengthValidator.new({}).validate(status)
      expect(status.errors[:text]).to be_empty
    end

    it 'stores a validator-sized excerpt for a long body, emoji, and a long title' do
      long_url = "https://example.com/#{'a' * 1800}"
      # The HTTP response cap is 1 MiB including the XML envelope, so a 1 MiB
      # article is stored through the parser and ingest path. The excerpt still
      # goes through Status.create!.
      document = rss_document(rss_item(guid: 'long', title: '題' * 800, link: long_url, body: 'a' * 1.megabyte))
      feed = ExternalBridge::RSS::Parser.parse!(document)
      response = ExternalBridge::RSS::Response.new(code: 200, body: '', etag: nil, last_modified: nil, final_url: feed_url)
      source, resources = ExternalBridge::RSS::Ingest.new.write_public!(feed, feed_url, response)
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active', checked_at: Time.current)
      ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: resources)
      resource = resources.first
      status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: resource.id).status_id)
      expect(resource.body.bytesize).to eq 1.megabyte
      expect_status_length(status)
      expect(status.text).to include('題')
      expect(status.text).to include(long_url)

      emoji_url = 'https://feeds.example/emoji.xml'
      stub_request(:get, emoji_url).to_return(status: 200, body: rss_document(rss_item(guid: 'emoji', body: '😀' * 2_000)))
      described_class.new.call(user: user, url: emoji_url)
      emoji_status = Status.find(ExternalStatusProjection.where(user_id: user.id).order(:id).last.status_id)
      expect_status_length(emoji_status)
      expect(emoji_status.text).to include('😀')
    end

    it 'updates an existing projection excerpt without dropping the shared body' do
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'rev', body: 'Short')))
      subscription = described_class.new.call(user: user, url: feed_url)
      resource = subscription.external_source.external_resources.first
      resource.update!(body: 'b' * 20_000, title: 'Updated title')
      ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: [resource.reload])
      status = Status.find(ExternalStatusProjection.find_by!(external_resource_id: resource.id).status_id)
      expect(resource.reload.body.bytesize).to eq 20_000
      expect(status.text).to include('Updated title')
      expect(status.text).not_to include('b' * 600)
      expect_status_length(status)
    end

    it 'continues the next item and the next subscriber when one projection fails' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'bad') + rss_item(guid: 'good', title: 'Good', link: 'https://example.com/good'))
      )
      fail_bad = true
      allow(ExternalBridge::ProjectionWriter).to receive(:new).and_wrap_original do |method, *args|
        writer = method.call(*args)
        allow(writer).to receive(:create!).and_wrap_original do |create, **kwargs|
          raise ActiveRecord::RecordInvalid, Status.new if fail_bad && kwargs[:resource].canonical_key.end_with?('item:bad')

          create.call(**kwargs)
        end
        writer
      end

      subscription = described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: other, url: feed_url)
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 1
      expect(ExternalResource.where(external_source_id: ExternalSource.find_by!(canonical_key: feed_url).id).count).to eq 2
      expect(subscription.reload.state).to eq 'active'
      expect(subscription.failed_item_count).to eq 1
      expect(subscription.last_error_code).to eq 'import_failed'
      expect(subscription.next_retry_at).to be > Time.current
      expect(ExternalProjectionFailure.where(user_id: user.id).count).to eq 1

      fail_bad = false
      source = subscription.external_source
      source.update!(fetched_at: 1.hour.ago, checked_at: 1.hour.ago)
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'C', title: 'Gamma', link: 'https://example.com/c')))
      ExternalBridge::RSS::RefreshSource.new.call(source.id)
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 3
      expect(subscription.reload.failed_item_count).to eq 0
      expect(subscription.last_error_code).to be_nil
      expect(ExternalProjectionFailure.where(user_id: user.id)).to be_empty
    end

    it 'does not report a subscription as synced when every item fails' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'bad') + rss_item(guid: 'worse', title: 'Worse', link: 'https://example.com/worse'))
      )
      allow(ExternalBridge::ProjectionWriter).to receive(:new).and_wrap_original do |method, *args|
        writer = method.call(*args)
        allow(writer).to receive(:create!).and_raise(ActiveRecord::RecordInvalid, Status.new)
        writer
      end

      subscription = described_class.new.call(user: user, url: feed_url)
      expect(ExternalStatusProjection.where(user_id: user.id)).to be_empty
      expect(subscription.reload.failed_item_count).to eq 2
      expect(subscription.last_error_code).to eq 'import_failed'
      expect(subscription.state).to eq 'active'
      expect(subscription.next_retry_at).to be_present
      expect(ExternalResource.where(external_source_id: subscription.external_source_id).count).to eq 2
    end
  end

  describe 'rolling feeds' do
    it 'retains items that a later fetch no longer lists' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'A', title: 'Alpha') + rss_item(guid: 'B', title: 'Beta', link: 'https://example.com/b'))
      )
      described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: other, url: feed_url)
      source = ExternalSource.find_by!(canonical_key: feed_url)
      source.update!(fetched_at: 1.hour.ago, checked_at: 1.hour.ago)

      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'C', title: 'Gamma', link: 'https://example.com/c')))
      ExternalBridge::RSS::RefreshSource.new.call(source.id)

      %w(A B).each do |guid|
        resource = ExternalResource.find_by!(canonical_key: ExternalBridge::RSS::Ingest.new.send(:resource_key, source, guid))
        expect(resource.source_deleted_at).to be_nil
        [user, other].each do |subscriber|
          marker = ExternalStatusProjection.find_by!(user_id: subscriber.id, external_resource_id: resource.id)
          expect(marker.source_deleted).to be false
          expect(Status.exists?(marker.status_id)).to be true
        end
      end
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 3
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 3
    end
  end

  describe 'unauthorized refresh' do
    it 'leaves shared source columns unchanged when the worker receives 401' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'guid-1', body: 'Public copy')),
        headers: { 'ETag' => 'W/"one"' }
      )
      described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: other, url: feed_url)
      source = ExternalSource.find_by!(canonical_key: feed_url)
      source.update!(fetched_at: 1.hour.ago)
      before_row = source.reload.attributes.slice('etag', 'title', 'checked_at', 'fetched_at', 'last_modified', 'updated_at', 'canonical_key')
      body = source.external_resources.first.body

      stub_request(:get, feed_url).to_return(status: 401, body: 'no', headers: { 'ETag' => 'W/"private"' })
      ExternalBridge::RSS::RefreshSourceWorker.new.perform(source.id)

      expect(source.reload.attributes.slice(*before_row.keys)).to eq before_row
      expect(source.external_resources.first.body).to eq body
      failed = ExternalSubscription.find_by!(user: user, external_source: source)
      expect(failed.state).to eq 'error'
      expect(failed.next_retry_at).to be_nil
      expect(ExternalSubscription.find_by!(user: other, external_source: source).state).to eq 'error'

      travel_to 2.days.from_now do
        expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)
        Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
      end
    end

    it 'does not fetch or enqueue for a subscriber who is not a tester' do
      Setting.external_bridge_rss_testers = ''
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, title: 'Held', fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
      ExternalSubscription.create!(user: user, external_source: source, state: 'active', checked_at: 2.hours.ago)
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'g')))

      expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)
      Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
      ExternalBridge::RSS::RefreshSourceWorker.new.perform(source.id)
      expect(a_request(:get, feed_url)).not_to have_been_made
      expect(source.reload.checked_at).to be_within(1.second).of(2.hours.ago)
    end
  end

  describe 'bounded keys and concurrent insert' do
    it 'stores two oversized guids as distinct bounded keys' do
      first = "g#{'a' * 4_000}"
      second = "g#{'b' * 4_000}"
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(
          rss_item(guid: first, title: 'One') +
          rss_item(guid: second, title: 'Two', link: 'https://example.com/two')
        )
      )
      described_class.new.call(user: user, url: feed_url)
      keys = ExternalSource.find_by!(canonical_key: feed_url).external_resources.pluck(:canonical_key)
      expect(keys.size).to eq 2
      expect(keys.uniq.size).to eq 2
      expect(keys).to all(start_with('digest:v1:'))
      expect(keys.map(&:bytesize)).to all(be <= ExternalBridge::RSS::Limits::MAX_RESOURCE_KEY_BYTES)
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 2
    end

    it 'reuses the resource when a concurrent insert wins the unique key' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/race.xml', title: 'Race')
      ExternalBridge::RSS::Parser
      item = ExternalBridge::RSS::Item.new(key: 'race-guid', title: 'Second', body: 'second body', canonical_url: 'https://example.com/race', byline: nil, published_at: nil, truncated: false)
      ingest = ExternalBridge::RSS::Ingest.new
      key = ingest.send(:resource_key, source, item.key)
      ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: key, title: 'First', body: 'first body')
      forced = false
      allow(ExternalResource).to receive(:find_or_initialize_by).and_wrap_original do |method, attrs|
        if !forced && attrs[:canonical_key] == key
          forced = true
          ExternalResource.new(protocol: 'rss', canonical_key: key)
        else
          method.call(attrs)
        end
      end

      saved = ingest.send(:upsert_resource!, source, nil, item)
      expect(ExternalResource.where(canonical_key: key).count).to eq 1
      expect(saved.reload.body).to eq 'second body'
    end
  end

  describe 'transient refresh' do
    def age_source(source)
      source.update!(fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
    end

    it 'retries a 503 and a 429 on the scheduler, then stops at the ceiling' do
      %w(503 429).each do |code|
        url = "https://feeds.example/retry-#{code}.xml"
        stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'first', body: 'Public')))
        subscription = described_class.new.call(user: user, url: url)
        source = subscription.external_source
        age_source(source)
        before_row = source.reload.attributes.slice('etag', 'title', 'checked_at', 'fetched_at', 'updated_at')

        stub_request(:get, url).to_return(status: code.to_i, body: 'later')
        ExternalBridge::RSS::RefreshSourceWorker.new.perform(source.id)
        subscription.reload
        expect(subscription.state).to eq 'active'
        expect(subscription.retry_count).to eq 1
        expect(subscription.last_error_code).to eq "http_#{code}"
        expect(subscription.next_retry_at).to be_within(2.seconds).of(Time.current + ExternalBridge::RSS::RetryPolicy.delay(1, subscription.id))
        expect(source.reload.attributes.slice(*before_row.keys)).to eq before_row
        expect(a_request(:get, url)).to have_been_made.times(2)

        Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
        expect(a_request(:get, url)).to have_been_made.times(2)

        stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'second', title: 'Back', link: 'https://example.com/back')))
        travel_to(subscription.next_retry_at + 1.second) do
          Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
        end
        expect(subscription.reload.state).to eq 'active'
        expect(subscription.retry_count).to eq 0
        expect(subscription.next_retry_at).to be_nil
        expect(subscription.last_error_code).to be_nil
        expect(ExternalStatusProjection.where(user_id: user.id, external_subscription_id: subscription.id).count).to eq 2
      end

      url = 'https://feeds.example/retry-ceiling.xml'
      stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'seed')))
      subscription = described_class.new.call(user: user, url: url)
      stub_request(:get, url).to_return(status: 503, body: 'down')
      ExternalBridge::RSS::RetryPolicy::CEILING.times do
        subscription.update!(next_retry_at: 1.second.ago) if subscription.reload.next_retry_at.present?
        ExternalBridge::RSS::RefreshSourceWorker.new.perform(subscription.external_source_id)
      end
      expect(subscription.reload.state).to eq 'error'
      expect(subscription.retry_count).to eq ExternalBridge::RSS::RetryPolicy::CEILING
      expect(subscription.next_retry_at).to be_nil
      made = a_request(:get, url)
      expect(made).to have_been_made.times(1 + ExternalBridge::RSS::RetryPolicy::CEILING)
      Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
      expect(made).to have_been_made.times(1 + ExternalBridge::RSS::RetryPolicy::CEILING)
    end
  end

  describe 'deleted projections' do
    it 'does not recreate a deleted item on refresh and restores it explicitly' do
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'keep', title: 'Keep') + rss_item(guid: 'drop', title: 'Drop', link: 'https://example.com/drop'))
      )
      owner = described_class.new.call(user: user, url: feed_url)
      described_class.new.call(user: other, url: feed_url)
      source = owner.external_source
      dropped = source.external_resources.find_by!(title: 'Drop')
      kept = ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: source.external_resources.find_by!(title: 'Keep').id)
      victim = ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: dropped.id)
      other_marker = ExternalStatusProjection.find_by!(user_id: other.id, external_resource_id: dropped.id)

      ExternalBridge::ProjectionPurge.purge_status!(Status.find(victim.status_id))
      expect(ExternalProjectionSuppression.find_by!(user_id: user.id, external_resource_id: dropped.id)).to be_present
      expect(Status.exists?(other_marker.status_id)).to be true
      expect(ExternalResource.exists?(dropped.id)).to be true

      source.update!(fetched_at: 1.hour.ago)
      stub_request(:get, feed_url).to_return(
        status: 200,
        body: rss_document(rss_item(guid: 'keep', title: 'Keep') + rss_item(guid: 'drop', title: 'Drop', link: 'https://example.com/drop'))
      )
      ExternalBridge::RSS::RefreshSource.new.call(source.id)
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: dropped.id)).to be_empty
      expect(Status.exists?(kept.status_id)).to be true
      expect(ExternalStatusProjection.find_by!(user_id: other.id, external_resource_id: dropped.id)).to be_present

      described_class.new.restore!(user: user, subscription_id: owner.id, resource_id: dropped.id)
      expect(ExternalProjectionSuppression.where(user_id: user.id, external_resource_id: dropped.id)).to be_empty
      expect(ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: dropped.id)).to be_present
    end
  end

  describe 'bounded keys and concurrent insert' do
    it 'takes a transaction advisory lock while writing the shared cache' do
      stub_request(:get, 'https://feeds.example/locked-write.xml').to_return(status: 200, body: rss_document(rss_item(guid: 'lock')))
      statements = []
      callback = lambda do |*, payload|
        statements << payload[:sql] if payload[:sql].include?('pg_advisory_xact_lock')
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.new.call(user: user, url: 'https://feeds.example/locked-write.xml')
      end
      expect(statements).not_to be_empty
      expect(ExternalSource.where(canonical_key: 'https://feeds.example/locked-write.xml').count).to eq 1
    end
  end
end
