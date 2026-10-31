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

    it 'does not fold a different selection query into the same source or projection' do
      selected = 'https://feeds.example/news.xml?exclude_body=1&order=created'
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'guid-1')))
      stub_request(:get, selected).to_return(status: 200, body: rss_document(rss_item(guid: 'guid-1')))

      plain = described_class.new.call(user: user, url: feed_url)
      other_subscription = described_class.new.call(user: other, url: selected)
      expect(other_subscription.external_source_id).not_to eq plain.external_source_id
      expect(ExternalSource.find(plain.external_source_id).canonical_key).to eq feed_url
      expect(ExternalSource.find(other_subscription.external_source_id).canonical_key).to eq selected
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id).pick(:status_id)).not_to eq(
        ExternalStatusProjection.where(user_id: other.id).pick(:status_id)
      )
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

    it 'does not keep a shared row when a public selection query returns 401, 403, or HTML' do
      url = 'https://feeds.example/closed.xml?format=rss2&exclude_body=1'
      stub_request(:get, url).to_return(status: 401, body: 'no')
      expect { described_class.new.call(user: user, url: url) }.to raise_error(ExternalBridge::Error)
      stub_request(:get, url).to_return(status: 403, body: 'no')
      expect { described_class.new.call(user: user, url: url) }.to raise_error(ExternalBridge::Error)
      stub_request(:get, url).to_return(status: 200, body: '<html><body>Not a feed</body></html>', headers: { 'Content-Type' => 'text/html' })
      expect { described_class.new.call(user: user, url: url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }
      expect(ExternalSource.where(canonical_key: url)).to be_empty
      expect(ExternalResource.where("canonical_key ILIKE '%closed.xml%'")).to be_empty
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
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
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

  describe 'public selection queries' do
    def atom_document
      <<~XML
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example Atom</title>
          <link href="https://example.com/"/>
          <entry>
            <id>urn:example:item-1</id>
            <title>Atom item</title>
            <link href="https://example.com/atom-1"/>
            <updated>2020-01-02T03:04:05Z</updated>
            <summary>Atom body</summary>
          </entry>
        </feed>
      XML
    end

    def rdf_document
      <<~XML
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
          <channel rdf:about="https://news.example/">
            <title>Example RDF</title>
            <link>https://news.example/</link>
            <item>
              <title>RDF item</title>
              <link>https://news.example/rdf-1</link>
              <description>RDF body</description>
            </item>
          </channel>
        </rdf:RDF>
      XML
    end

    def selection_cases
      [
        ['combo-rss.xml?format=rss&feed=rss2&alt=rss&exclude_body=0&include_scraps=0&all=0', rss_document(rss_item(guid: 'combo-rss')), 'rss', 'combo-rss'],
        ['combo-atom.xml?format=atom&exclude_body=1&include_scraps=1&all=1&order=created&period=weekly', atom_document, 'atom', 'urn:example:item-1'],
        ['format-xml.xml?format=xml', rss_document(rss_item(guid: 'format-xml')), 'rss', 'format-xml'],
        ['format-feed.xml?format=feed', rss_document(rss_item(guid: 'format-feed')), 'rss', 'format-feed'],
        ['format-rss2.xml?format=rss2', rss_document(rss_item(guid: 'format-rss2')), 'rss', 'format-rss2'],
        ['format-rdf.xml?format=rss_200', rdf_document, 'rss', 'https://news.example/rdf-1'],
        ['format-enc.xml?format=rss_200_enc', rss_document(rss_item(guid: 'format-enc')), 'rss', 'format-enc'],
      ]
    end

    it 'subscribes and refreshes every finite value without collapsing different conditions' do
      stored = selection_cases.map do |suffix, body, protocol, item_key|
        url = "https://feeds.example/sel/#{suffix}"
        stub_request(:get, url).to_return(status: 200, body: body, headers: { 'Content-Type' => 'application/xml' })
        subscription = described_class.new.call(user: user, url: url)
        source = subscription.external_source
        resource = source.external_resources.find_by!("canonical_key LIKE ?", "%item:#{item_key}")
        projection = ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: resource.id)
        expect(source.canonical_key).to eq url
        expect(source.protocol).to eq protocol
        { url: url, source_id: source.id, resource_id: resource.id, projection_id: projection.id, item_key: item_key }
      end
      expect(stored.map { |row| row[:source_id] }.uniq.size).to eq stored.size

      mixed = 'https://feeds.example/sel/combo-rss.xml?FORMAT=RSS&Feed=RSS2&Alt=RSS&Exclude_Body=0&Include_Scraps=0&All=0'
      again = described_class.new.call(user: other, url: mixed)
      expect(again.external_source_id).to eq stored.first[:source_id]
      chosen = ExternalBridge::RSS::InitialLanguage.attributes_for(again.external_source)
      expect(again.language_mode).to eq chosen[:language_mode]
      expect(again.language).to eq chosen[:language]
      kept = stored.map do |row|
        subscription = ExternalSubscription.find_by!(user: user, external_source_id: row[:source_id])
        [subscription.language_mode, subscription.language]
      end
      again.update!(language_mode: 'fixed', language: 'ja')

      stored.each do |row|
        ExternalBridge::RSS::RefreshSource.new.call(row[:source_id], subscription_id: again.external_source_id == row[:source_id] ? again.id : ExternalSubscription.find_by!(user: user, external_source_id: row[:source_id]).id)
        resource = ExternalResource.find(row[:resource_id])
        expect(resource.canonical_key).to include("item:#{row[:item_key]}")
        expect(ExternalStatusProjection.find(row[:projection_id]).external_resource_id).to eq resource.id
        expect(ExternalSource.find(row[:source_id]).canonical_key).to eq row[:url]
      end
      expect(again.reload.language_mode).to eq 'fixed'
      expect(again.language).to eq 'ja'
      stored.each_with_index do |row, index|
        subscription = ExternalSubscription.find_by!(user: user, external_source_id: row[:source_id])
        expect([subscription.language_mode, subscription.language]).to eq kept[index]
      end
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq stored.size
      expect(ExternalStatusProjection.where(user_id: other.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)).not_to include(
        ExternalStatusProjection.find_by!(user_id: other.id).status_id
      )
    end

    it 'follows a redirect hop only when that hop is still a public feed query' do
      start = 'https://feeds.example/start.xml?format=rss'
      hop = 'https://feeds.example/next.xml?format=rss_200&exclude_body=1'
      stub_request(:get, start).to_return(status: 302, headers: { 'Location' => hop })
      stub_request(:get, hop).to_return(status: 200, body: rss_document(rss_item(guid: 'hopped')))
      described_class.new.call(user: user, url: start)
      expect(ExternalSource.find_by!(canonical_key: hop).external_resources.first.canonical_key).to include('item:hopped')

      {
        'https://feeds.example/token-start.xml' => 'https://feeds.example/hidden.xml?format=rss&auth_token=SECRET',
        'https://feeds.example/encoded-start.xml' => 'https://feeds.example/encoded-hidden.xml?format=rss%26token%3DSECRET',
        'https://feeds.example/unknown-start.xml' => 'https://feeds.example/unknown.xml?format=rss2&channel=news',
        'https://feeds.example/dup-start.xml' => 'https://feeds.example/dup.xml?format=rss&FORMAT=atom',
        'https://feeds.example/private-start.xml?period=weekly' => 'http://127.0.0.1/secret.xml',
        'https://feeds.example/userinfo-start.xml' => 'https://user:pw@feeds.example/userinfo.xml?format=rss',
      }.each do |from, location|
        stub_request(:get, from).to_return(status: 302, headers: { 'Location' => location })
        stub_request(:get, location).to_return(status: 200, body: rss_document(rss_item(guid: 'leaked')))
        expect { described_class.new.call(user: user, url: from) }
          .to raise_error(ExternalBridge::Error), from
        expect(a_request(:get, location)).not_to have_been_made
      end
      expect(a_request(:get, /hidden\.xml|encoded-hidden|unknown\.xml|dup\.xml|127\.0\.0\.1|userinfo\.xml/)).not_to have_been_made
      expect(ExternalSource.where("canonical_key ILIKE '%secret%'")).to be_empty
    end

    it 'keeps the final URL when two different queries redirect to one feed' do
      left = 'https://feeds.example/left.xml?format=rss'
      right = 'https://feeds.example/right.xml?exclude_body=1'
      final = 'https://feeds.example/final.xml'
      stub_request(:get, left).to_return(status: 302, headers: { 'Location' => final })
      stub_request(:get, right).to_return(status: 302, headers: { 'Location' => final })
      stub_request(:get, final).to_return(status: 200, body: rss_document(rss_item(guid: 'final-item')))

      first = described_class.new.call(user: user, url: left)
      second = described_class.new.call(user: other, url: right)
      expect(second.external_source_id).to eq first.external_source_id
      expect(ExternalSource.find(first.external_source_id).canonical_key).to eq final
      expect(ExternalSource.where(canonical_key: [left, right])).to be_empty
      expect(ExternalResource.where(external_source_id: first.external_source_id).count).to eq 1
    end

    it 'does not request NodeInfo or ActivityPub URLs that use a feed selection query' do
      nodeinfo = 'https://feeds.example/nodeinfo/2.1?exclude_body=1'
      legacy = 'https://feeds.example/nodeinfo/2.1?format=rss'
      activity = 'https://posts.example/users/alice/statuses/1?format=rss2'
      viewkey = 'https://posts.example/users/alice/statuses/1?viewkey=abc'
      stub_request(:get, nodeinfo).to_return(status: 200, body: '{}')
      stub_request(:get, legacy).to_return(status: 404, body: '')
      stub_request(:get, activity).to_return(status: 200, body: '{}')
      stub_request(:get, viewkey).to_return(status: 200, body: '{}')

      expect do
        ExternalBridge::RSS::HttpClient.get(nodeinfo, profile: ExternalBridge::RSS::HttpClient::NODEINFO_PROFILE, origin: 'https://feeds.example')
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
      ExternalBridge::RSS::HttpClient.get(legacy, profile: ExternalBridge::RSS::HttpClient::NODEINFO_PROFILE, origin: 'https://feeds.example')
      expect do
        ExternalBridge::RSS::HttpClient.get(activity, profile: ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE)
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
      expect do
        ExternalBridge::RSS::HttpClient.get(viewkey, profile: ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE)
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }

      expect(a_request(:get, nodeinfo)).not_to have_been_made
      expect(a_request(:get, legacy)).to have_been_made.once
      expect(a_request(:get, activity)).not_to have_been_made
      expect(a_request(:get, viewkey)).not_to have_been_made
    end

    context 'with a private DNS answer' do
      around do |example|
        WebMock.disable!
        example.run
        WebMock.enable!
      end

      it 'does not open a feed request when the host resolves to a private address' do
        resolver = double
        allow(resolver).to receive(:getaddresses).and_return([Resolv::IPv4.create('10.0.0.8')])
        allow(resolver).to receive(:timeouts=)
        allow(Resolv::DNS).to receive(:open).and_yield(resolver)

        expect do
          ExternalBridge::RSS::HttpClient.get('https://feeds.example/news.xml?format=rss2&exclude_body=1')
        end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'private_address' }
      end
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
      expect(logged).to include("source_id=#{source.id}")
      expect(logged).to include('outcome=fetch_failed')
      expect(logged).to include('error_code=fetch_failed')
      expect(logged).not_to include(source.canonical_key)
      expect(logged).not_to include('encrypted_payload')
    end
  end

  describe 'identifier feed queries' do
    let(:channel) { "UC#{'0' * 22}" }
    let(:youtube) { "https://www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}" }
    let(:flickr_tags) { 'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat%2CDog&tagmode=any' }
    let(:flickr_other) { 'https://www.flickr.com/services/feeds/photos_public.gne?tags=cat' }

    def rss_body(guid)
      rss_document(rss_item(guid: guid))
    end

    it 'subscribes, refreshes, and shares an identifier feed without collapsing a different one' do
      stub_request(:get, youtube).to_return(status: 200, body: rss_body('channel-item'), headers: { 'Content-Type' => 'application/xml' })
      stub_request(:get, flickr_tags).to_return(status: 200, body: rss_body('tag-item'), headers: { 'Content-Type' => 'application/xml' })
      stub_request(:get, flickr_other).to_return(status: 200, body: rss_body('tag-item'), headers: { 'Content-Type' => 'application/xml' })

      first = described_class.new.call(user: user, url: "https://www.youtube.com/xml/feeds/videos.xml?CHANNEL_ID=#{channel}")
      again = described_class.new.call(user: user, url: youtube)
      second_user = described_class.new.call(user: other, url: youtube)
      tagged = described_class.new.call(user: user, url: 'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat,Dog&tagmode=ANY')
      other_tags = described_class.new.call(user: user, url: flickr_other)

      source = first.external_source
      expect(again.external_source_id).to eq source.id
      expect(second_user.external_source_id).to eq source.id
      expect(source.canonical_key).to eq youtube
      expect(tagged.external_source.canonical_key).to eq flickr_tags
      expect(other_tags.external_source_id).not_to eq tagged.external_source_id
      channel_resource = source.external_resources.find_by!("canonical_key LIKE ?", '%item:channel-item')
      tag_resource = tagged.external_source.external_resources.find_by!("canonical_key LIKE ?", '%item:tag-item')
      expect(channel_resource.canonical_key).to include(youtube)
      expect(tag_resource.canonical_key).to include('tags=Cat%2CDog')
      expect(tag_resource.canonical_key).not_to eq other_tags.external_source.external_resources.first.canonical_key

      first.update!(language_mode: 'fixed', language: 'ja', media_sensitive: true, cw_enabled: true)
      ExternalBridge::RSS::RefreshSource.new.call(source.id, subscription_id: first.id)
      expect(first.reload.language_mode).to eq 'fixed'
      expect(first.language).to eq 'ja'
      expect(first.media_sensitive).to be true
      expect(first.cw_enabled).to be true
      expect(source.reload.external_resources.count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: channel_resource.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: other.id, external_resource_id: channel_resource.id).count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)).not_to include(
        ExternalStatusProjection.find_by!(user_id: other.id, external_resource_id: channel_resource.id).status_id
      )
    end

    it 'follows a redirect only when the next hop still matches that hop' do
      start = 'https://feeds.example/start.xml'
      stub_request(:get, start).to_return(status: 302, headers: { 'Location' => youtube })
      stub_request(:get, youtube).to_return(status: 200, body: rss_body('hopped-channel'))
      described_class.new.call(user: user, url: start)
      expect(ExternalSource.find_by!(canonical_key: youtube).external_resources.first.canonical_key).to include('item:hopped-channel')

      upper = 'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000%40N99'
      lower = 'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000%40n99'
      stub_request(:get, upper).to_return(status: 302, headers: { 'Location' => lower })
      stub_request(:get, lower).to_return(status: 200, body: rss_body('lower-nsid'))
      described_class.new.call(user: other, url: 'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000@N99')
      expect(ExternalSource.find_by!(canonical_key: lower)).to be_present
      expect(ExternalSource.where(canonical_key: upper)).to be_empty

      other_channel = "https://www.youtube.com/xml/feeds/videos.xml?channel_id=UC#{'0' * 21}a"
      denied = {
        other_channel => "https://www.youtube.com/feeds/videos.xml?channel_id=#{channel}",
        'https://feeds.example/carry.xml' => "https://evil.example/xml/feeds/videos.xml?channel_id=#{channel}",
        'https://feeds.example/flickr-key.xml' => 'https://www.youtube.com/xml/feeds/videos.xml?tags=Cat',
        'https://feeds.example/secret-id.xml' => "#{youtube}&token=SECRET",
        'https://feeds.example/literal.xml' => 'http://127.0.0.1/xml/feeds/videos.xml?format=rss',
        'https://feeds.example/userinfo.xml' => "https://user:pw@www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}",
      }
      denied.each do |from, location|
        stub_request(:get, from).to_return(status: 302, headers: { 'Location' => location })
        stub_request(:get, location).to_return(status: 200, body: rss_body('leaked'))
        expect { described_class.new.call(user: user, url: from) }.to raise_error(ExternalBridge::Error), from
        expect(a_request(:get, location)).not_to have_been_made
      end
      expect(ExternalSource.where("canonical_key ILIKE '%secret%'")).to be_empty
    end

    it 'sends the canonical redirect target and stores that response' do
      channel_value = "UC#{'0' * 21}A"
      cases = {
        'https://feeds.example/finite-jump.xml' => [
          'https://feeds.example/finite.xml?FORMAT=%2572ss_200',
          'https://feeds.example/finite.xml?format=rss_200',
          'finite-canonical',
        ],
        'https://feeds.example/tag-jump.xml' => [
          'https://www.flickr.com/services/feeds/photos_public.gne?TAGS=Cat',
          'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat',
          'tag-canonical',
        ],
        'https://feeds.example/comma-jump.xml' => [
          'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat%252CDog',
          'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat%2CDog',
          'comma-canonical',
        ],
        'https://feeds.example/channel-jump.xml' => [
          "https://www.youtube.com/xml/feeds/videos.xml?CHANNEL_ID=#{channel_value}",
          "https://www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel_value}",
          'channel-canonical',
        ],
        'https://feeds.example/nsid-jump.xml' => [
          'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000@N99',
          'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000%40N99',
          'nsid-canonical',
        ],
        'https://feeds.example/nsid-lower-jump.xml' => [
          'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000@n99',
          'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000%40n99',
          'nsid-lower-canonical',
        ],
      }

      # WebMock's signature normalizes the default port and some escapes.
      # Record HTTP::Request#uri, which is the URI Client#perform sends.
      sent = []
      allow_any_instance_of(HTTP::Request).to receive(:webmock_signature).and_wrap_original do |original|
        sent << original.receiver.uri.to_s
        original.call
      end

      cases.each do |start, (raw, canonical, guid)|
        sent.clear
        answer = lambda do |_request|
          body = sent.last == canonical ? rss_body(guid) : rss_body("raw-#{guid}")
          { status: 200, body: body, headers: { 'Content-Type' => 'application/xml' } }
        end
        stub_request(:get, raw).to_return(&answer)
        stub_request(:get, canonical).to_return(&answer)
        stub_request(:get, start).to_return(status: 302, headers: { 'Location' => raw })

        subscription = described_class.new.call(user: user, url: start)
        expect(sent).to include(canonical), sent.inspect
        expect(sent).not_to include(raw)
        expect(sent.last).to eq(canonical)
        expect(subscription.external_source.canonical_key).to eq canonical
        expect(subscription.external_source.external_resources.first.canonical_key).to include("item:#{guid}")
        expect(subscription.external_source.external_resources.first.canonical_key).not_to include("raw-#{guid}")
      end
    end

    it 'keeps one final URL when two identifier feeds redirect to the same document' do
      final = 'https://feeds.example/final.xml'
      stub_request(:get, youtube).to_return(status: 302, headers: { 'Location' => final })
      stub_request(:get, flickr_other).to_return(status: 302, headers: { 'Location' => final })
      stub_request(:get, final).to_return(status: 200, body: rss_body('final-item'))

      first = described_class.new.call(user: user, url: youtube)
      second = described_class.new.call(user: other, url: flickr_other)
      expect(second.external_source_id).to eq first.external_source_id
      expect(ExternalSource.find(first.external_source_id).canonical_key).to eq final
      expect(ExternalSource.where(canonical_key: [youtube, flickr_other])).to be_empty
    end

    it 'does not fetch an identifier query on NodeInfo, ActivityPub, media, poster, or icon profiles' do
      targets = [
        [ExternalBridge::RSS::HttpClient::NODEINFO_PROFILE, "https://www.youtube.com/.well-known/nodeinfo?channel_id=#{channel}", 'https://www.youtube.com'],
        [ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE, "https://posts.example/users/alice/statuses/1?channel_id=#{channel}", nil],
        [ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE, 'https://posts.example/users/alice/statuses/1?tags=Cat&tagmode=any', nil],
        [ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE, 'https://posts.example/users/alice/statuses/1?viewkey=abc', nil],
        [ExternalBridge::RSS::HttpClient::MEDIA_IMAGE_PROFILE, 'https://cdn.example/a.jpg?tags=Cat', nil],
        [ExternalBridge::RSS::HttpClient::MEDIA_POSTER_PROFILE, "https://images.example/p.jpg?channel_id=#{channel}", nil],
        [ExternalBridge::RSS::HttpClient::ICON_IMAGE_PROFILE, "https://cdn.example/a.png?channel_id=#{channel}", nil],
      ]
      targets.each do |profile, url, origin|
        stub_request(:get, url).to_return(status: 200, body: '{}')
        expect { ExternalBridge::RSS::HttpClient.get(url, profile: profile, origin: origin) }
          .to raise_error(ExternalBridge::Error), url
        expect(a_request(:get, url)).not_to have_been_made
      end
    end

    context 'with a private DNS answer' do
      around do |example|
        WebMock.disable!
        example.run
        WebMock.enable!
      end

      it 'does not open an identifier feed when the host resolves to a private address' do
        resolver = double
        allow(resolver).to receive(:getaddresses).and_return([Resolv::IPv4.create('10.0.0.8')])
        allow(resolver).to receive(:timeouts=)
        allow(Resolv::DNS).to receive(:open).and_yield(resolver)

        expect do
          ExternalBridge::RSS::HttpClient.get(youtube)
        end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'private_address' }
      end
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
        'https://feeds.example/rss?p=123',
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

    it 'rejects duplicate keys, encoded delimiters, and a known key mixed with a credential before a request or a log line' do
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message.to_s }
      allow(Rails.logger).to receive(:error) { |message| messages << message.to_s }
      urls = [
        'https://feeds.example/rss?format=rss&FORMAT=atom',
        'https://feeds.example/rss?format=rss%26token%3DSECRET',
        'https://feeds.example/rss?format=rss%3Bauth%3DSECRET',
        'https://feeds.example/rss?format=rss&signature=SECRET',
        'https://feeds.example/rss?exclude_body=1&token=SECRET',
        'https://feeds.example/rss?format=',
        'https://feeds.example/rss?format=rss&',
        'https://user:pw@feeds.example/rss?format=rss2&auth_token=SECRET',
      ]

      urls.each do |url|
        expect { described_class.new.call(user: user, url: url) }
          .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
      end

      logged = messages.join("\n")
      expect(logged).not_to include('SECRET')
      expect(logged).not_to include('user:pw')
      expect(ExternalSource.where("canonical_key ILIKE '%secret%'")).to be_empty
      expect(a_request(:get, /SECRET|user:pw/)).not_to have_been_made
    end
  end

  describe 'status excerpt' do
    def expect_status_length(status)
      StatusLengthValidator.new({}).validate(status)
      expect(status.errors[:text]).to be_empty
    end

    it 'stores a validator-sized excerpt for a long body, emoji, and a long title' do
      long_url = "https://example.com/#{'a' * 1800}"
      # The per-item text cap remains 1 MiB independently of the expanded
      # 4 MiB feed download cap. The excerpt still goes through Status.create!.
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
      subscription.update!(next_retry_at: 1.second.ago)
      ExternalProjectionFailure.where(user_id: user.id).update_all(next_attempt_at: 1.second.ago)
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
      ExternalSubscription.where(external_source_id: source.id).update_all(checked_at: 2.hours.ago)

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
      ExternalSubscription.where(external_source_id: source.id).update_all(checked_at: 2.hours.ago)

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
        subscription.update!(checked_at: 2.hours.ago)
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
      subscription.update!(checked_at: 2.hours.ago)
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
      ExternalSubscription.where(external_source_id: source.id).update_all(checked_at: 2.hours.ago)
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

  describe 'staggered subscriber backoff' do
    let(:url) { 'https://feeds.example/stagger.xml' }

    def subscribe_both
      stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'shared', title: 'Shared')))
      owner = described_class.new.call(user: user, url: url)
      described_class.new.call(user: other, url: url)
      owner.external_source
    end

    it 'does not advance a waiting subscriber when another subscriber is due' do
      source = subscribe_both
      waiting = ExternalSubscription.find_by!(user: other, external_source: source)
      due = ExternalSubscription.find_by!(user: user, external_source: source)
      waiting.update!(retry_count: 2, next_retry_at: 4.hours.from_now, last_error_code: 'http_429', checked_at: Time.current)
      due.update!(checked_at: 2.hours.ago, next_retry_at: nil, retry_count: 0)
      waiting_deadline = waiting.next_retry_at
      waiting_checked = waiting.checked_at

      stub_request(:get, url).to_return(status: 429, body: 'slow')
      Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform

      due.reload
      waiting.reload
      expect(due.retry_count).to eq 1
      expect(due.last_error_code).to eq 'http_429'
      expect(waiting.retry_count).to eq 2
      expect(waiting.next_retry_at).to be_within(1.second).of(waiting_deadline)
      expect(waiting.checked_at).to be_within(1.second).of(waiting_checked)
      expect(waiting.last_error_code).to eq 'http_429'
      expect(a_request(:get, url)).to have_been_made.times(2)

      due.update!(next_retry_at: 1.second.ago)
      stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'fresh', title: 'Fresh', link: 'https://example.com/fresh')))
      Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform

      waiting.reload
      fresh = source.external_resources.find_by!(title: 'Fresh')
      expect(ExternalStatusProjection.find_by!(user_id: other.id, external_resource_id: fresh.id)).to be_present
      expect(waiting.retry_count).to eq 2
      expect(waiting.next_retry_at).to be_within(1.second).of(waiting_deadline)
      expect(waiting.checked_at).to be_within(1.second).of(waiting_checked)
      expect(waiting.last_error_code).to eq 'http_429'
    end

    it 'accounts a targeted resume without charging the other subscriber' do
      source = subscribe_both
      waiting = ExternalSubscription.find_by!(user: other, external_source: source)
      resumed = ExternalSubscription.find_by!(user: user, external_source: source)
      waiting.update!(retry_count: 3, next_retry_at: 5.hours.from_now, last_error_code: 'http_503', checked_at: 1.hour.ago)
      resumed.update!(state: 'error', retry_count: 5, next_retry_at: nil, last_error_code: 'http_503')
      deadline = waiting.next_retry_at

      stub_request(:get, url).to_return(status: 429, body: 'slow')
      described_class.new.resume!(user: user, subscription_id: resumed.id)

      expect(resumed.reload.retry_count).to eq 1
      expect(resumed.last_error_code).to eq 'http_429'
      expect(waiting.reload.retry_count).to eq 3
      expect(waiting.next_retry_at).to be_within(1.second).of(deadline)
      expect(waiting.last_error_code).to eq 'http_503'
    end
  end

  describe 'bounded historical retries' do
    it 'retries a bounded oldest page and later reaches the items it skipped' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/backlog.xml', title: 'Backlog', fetched_at: Time.current, checked_at: Time.current)
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active', checked_at: Time.current)
      resources = Array.new(ExternalBridge::RSS::Limits::MAX_ITEMS + 5) do |index|
        ExternalResource.create!(
          external_source: source,
          protocol: 'rss',
          canonical_key: "hist-#{index}",
          title: "Historical #{index}",
          body: 'rotated out'
        )
      end
      resources.each_with_index do |resource, index|
        failure = ExternalProjectionFailure.create!(
          user: user,
          external_subscription: subscription,
          external_resource: resource,
          error_code: 'import_failed',
          attempt_count: 0
        )
        failure.update_columns(created_at: (resources.size - index).minutes.ago)
      end

      failing = true
      allow(ExternalBridge::ProjectionWriter).to receive(:new).and_wrap_original do |method, *args|
        writer = method.call(*args)
        allow(writer).to receive(:create!).and_wrap_original do |create, **kwargs|
          raise ActiveRecord::RecordInvalid, Status.new if failing

          create.call(**kwargs)
        end
        writer
      end

      materialize = ExternalBridge::RSS::Materialize.new
      first = materialize.call(subscription: subscription, resources: [], retries: true)
      expect(first.attempted).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
      oldest = resources.first(ExternalBridge::RSS::Limits::MAX_ITEMS)
      newest = resources.last(5)
      expect(ExternalProjectionFailure.where(external_resource_id: oldest.map(&:id)).pluck(:attempt_count).uniq).to eq [1]
      expect(ExternalProjectionFailure.where(external_resource_id: newest.map(&:id)).pluck(:attempt_count).uniq).to eq [0]

      second = materialize.call(subscription: subscription, resources: [], retries: true)
      expect(second.attempted).to eq 5
      expect(ExternalProjectionFailure.where(external_resource_id: oldest.map(&:id)).pluck(:attempt_count).uniq).to eq [1]
      expect(ExternalProjectionFailure.where(external_resource_id: newest.map(&:id)).pluck(:attempt_count).uniq).to eq [1]

      failing = false
      travel_to(20.minutes.from_now) do
        third = materialize.call(subscription: subscription, resources: [], retries: true)
        expect(third.succeeded).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
      end
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: newest.map(&:id))).to be_empty

      travel_to(40.minutes.from_now) do
        fourth = materialize.call(subscription: subscription.reload, resources: [], retries: true)
        expect(fourth.succeeded).to eq 5
      end
      expect(ExternalStatusProjection.where(user_id: user.id).count).to eq resources.size
      expect(ExternalProjectionFailure.where(external_subscription_id: subscription.id)).to be_empty
    end

    it 'reads failure state for the current page ids and a limited historical page' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/page-scope.xml', title: 'Scope', fetched_at: Time.current, checked_at: Time.current)
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active', checked_at: Time.current)
      current_resources = Array.new(2) do |index|
        ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: "cur-#{index}", title: "Current #{index}", body: 'now')
      end
      ExternalProjectionFailure.create!(
        user: user,
        external_subscription: subscription,
        external_resource: current_resources.first,
        error_code: 'import_failed',
        attempt_count: 1,
        next_attempt_at: 2.hours.from_now
      )
      historical = Array.new(ExternalBridge::RSS::Limits::MAX_ITEMS + 5) do |index|
        ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: "old-#{index}", title: "Old #{index}", body: 'later')
      end
      historical.each_with_index do |resource, index|
        failure = ExternalProjectionFailure.create!(
          user: user,
          external_subscription: subscription,
          external_resource: resource,
          error_code: 'import_failed',
          attempt_count: 0
        )
        failure.update_columns(created_at: (historical.size - index).minutes.ago, next_attempt_at: nil)
      end

      entries = []
      callback = lambda do |*, payload|
        entries << payload unless payload[:name] == 'SCHEMA'
      end
      result = nil
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        result = ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: current_resources, retries: true)
      end

      failure_selects = entries.select { |payload| payload[:sql].to_s.match?(/select/i) && payload[:sql].include?('external_projection_failures') }
      unbounded = failure_selects.reject { |payload| payload[:sql].match?(/LIMIT/i) || payload[:sql].include?('external_resource_id') }
      expect(unbounded).to be_empty
      page_lookup = failure_selects.find do |payload|
        sql = payload[:sql]
        next false if sql.match?(/LIMIT/i) || sql.match?(/NOT/i)

        binds = Array(payload[:type_casted_binds]).flatten.map(&:to_s)
        current_resources.all? { |resource| binds.include?(resource.id.to_s) || sql.include?(resource.id.to_s) }
      end
      expect(page_lookup).to be_present
      expect(failure_selects.any? { |payload| payload[:sql].match?(/LIMIT/i) }).to be true
      expect(result.attempted).to eq(1 + ExternalBridge::RSS::Limits::MAX_ITEMS)
      expect(ExternalProjectionFailure.find_by!(external_resource_id: current_resources.first.id).attempt_count).to eq 1
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: current_resources.second.id)).to exist
    end

    it 'imports a parked item again after the owner resumes' do
      url = 'https://feeds.example/resume-parked.xml'
      stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'live', title: 'Live')))
      subscription = described_class.new.call(user: user, url: url)
      parked = ExternalResource.create!(
        external_source: subscription.external_source,
        protocol: 'rss',
        canonical_key: 'hist-parked',
        title: 'Parked',
        body: 'come back'
      )
      ExternalProjectionFailure.create!(
        user: user,
        external_subscription: subscription,
        external_resource: parked,
        error_code: 'import_failed',
        attempt_count: ExternalBridge::RSS::Limits::ITEM_ATTEMPT_CEILING,
        next_attempt_at: nil
      )

      described_class.new.resume!(user: user, subscription_id: subscription.id)

      expect(ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: parked.id)).to be_present
      expect(ExternalProjectionFailure.where(external_resource_id: parked.id)).to be_empty
    end

    it 'parks a bad guid that stays in the feed and imports it only after resume' do
      url = 'https://feeds.example/stuck-guid.xml'
      document = rss_document(rss_item(guid: 'bad', title: 'Bad') + rss_item(guid: 'good', title: 'Good', link: 'https://example.com/good'))
      stub_request(:get, url).to_return(status: 200, body: document)
      failing = true
      allow(ExternalBridge::ProjectionWriter).to receive(:new).and_wrap_original do |method, *args|
        writer = method.call(*args)
        allow(writer).to receive(:create!).and_wrap_original do |create, **kwargs|
          raise ActiveRecord::RecordInvalid, Status.new if failing && kwargs[:resource].canonical_key.end_with?('item:bad')

          create.call(**kwargs)
        end
        writer
      end

      subscription = described_class.new.call(user: user, url: url)
      source = subscription.external_source
      failure = ExternalProjectionFailure.find_by!(external_subscription_id: subscription.id)
      expect(failure.attempt_count).to eq 1
      expect(failure.next_attempt_at).to be > Time.current
      expect(subscription.reload.retry_count).to eq 0
      expect(subscription.state).to eq 'active'

      source.update!(fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
      subscription.update!(next_retry_at: 1.second.ago, checked_at: 2.hours.ago)
      ExternalBridge::RSS::RefreshSource.new.call(source.id)
      expect(failure.reload.attempt_count).to eq 1

      (ExternalBridge::RSS::Limits::ITEM_ATTEMPT_CEILING - 1).times do
        failure.update!(next_attempt_at: 1.second.ago)
        subscription.update!(state: 'active', next_retry_at: 1.second.ago, checked_at: 2.hours.ago)
        source.update!(fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
        ExternalBridge::RSS::RefreshSource.new.call(source.id)
      end
      expect(failure.reload.attempt_count).to eq ExternalBridge::RSS::Limits::ITEM_ATTEMPT_CEILING
      expect(failure.next_attempt_at).to be_nil
      expect(subscription.reload.state).to eq 'active'
      expect(subscription.retry_count).to eq 0
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: failure.external_resource_id)).to be_empty

      3.times do
        subscription.update!(state: 'active', next_retry_at: nil, checked_at: 2.hours.ago)
        source.update!(fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
        ExternalBridge::RSS::RefreshSource.new.call(source.id)
        expect(failure.reload.attempt_count).to eq ExternalBridge::RSS::Limits::ITEM_ATTEMPT_CEILING
      end

      failing = false
      described_class.new.resume!(user: user, subscription_id: subscription.id)
      expect(ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: failure.external_resource_id)).to be_present
      expect(ExternalProjectionFailure.where(id: failure.id)).to be_empty
    end

    it 'drains more than five pages of importable failures without a terminal error' do
      url = 'https://pages.example/backlog.xml'
      stub_request(:get, url).to_return(status: 200, body: rss_document(rss_item(guid: 'live', title: 'Live')))
      subscription = described_class.new.call(user: user, url: url)
      source = subscription.external_source
      pages = ExternalBridge::RSS::RetryPolicy::CEILING + 1
      total = pages * ExternalBridge::RSS::Limits::MAX_ITEMS
      total.times do |index|
        resource = ExternalResource.create!(
          external_source: source,
          protocol: 'rss',
          canonical_key: "page-#{index}",
          title: "Page #{index}",
          body: 'ready'
        )
        failure = ExternalProjectionFailure.create!(
          user: user,
          external_subscription: subscription,
          external_resource: resource,
          error_code: 'import_failed',
          attempt_count: 0
        )
        failure.update_columns(created_at: (total - index).minutes.ago, next_attempt_at: nil)
      end

      subscription.update!(next_retry_at: 1.second.ago, checked_at: 2.hours.ago)
      pages.times do
        expect(subscription.reload.state).to eq 'active'
        Scheduler::ExternalBridgeRSSRefreshScheduler.new.perform
      end

      expect(subscription.reload.state).to eq 'active'
      expect(subscription.retry_count).to eq 0
      expect(subscription.last_error_code).to be_nil
      expect(ExternalProjectionFailure.where(external_subscription_id: subscription.id)).to be_empty
      expect(ExternalStatusProjection.where(external_subscription_id: subscription.id).count).to eq(total + 1)
    end
  end

  describe 'RSS 1.0' do
    let(:rdf) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel rdf:about="https://news.example/">
            <title>Example RDF</title>
            <link>https://news.example/</link>
            <description>Public RSS 1.0</description>
            <items>
              <rdf:Seq>
                <rdf:li rdf:resource="https://news.example/second" />
                <rdf:li rdf:resource="https://news.example/first " />
              </rdf:Seq>
            </items>
            <image rdf:resource="https://news.example/logo.png" />
          </channel>
          <image rdf:about="https://news.example/logo.png">
            <title>Logo</title>
            <url>https://news.example/logo.png</url>
            <link>https://news.example/</link>
          </image>
          <item rdf:about="https://news.example/first ">
            <title>First</title>
            <link>https://news.example/first </link>
            <dc:creator>Ada</dc:creator>
            <dc:date>2026-10-26T13:33:00+09:00</dc:date>
            <content:encoded><![CDATA[<p>Visible</p><script>alert(1)</script>]]></content:encoded>
          </item>
          <item rdf:about="https://news.example/second">
            <title>Second</title>
            <link>https://news.example/second</link>
            <description>Summary only</description>
            <dc:date>not-a-date</dc:date>
          </item>
          <item rdf:about="https://news.example/notes#section">
            <title>Fragment</title>
            <link>https://news.example/notes#section</link>
            <description>Kept by about</description>
            <dc:date>2026-10-22T14:27:00+09:00</dc:date>
          </item>
        </rdf:RDF>
      XML
    end

    %w(application/xml text/xml text/html).each do |content_type|
      it "subscribes a public RSS 1.0 document served as #{content_type}" do
        stub_request(:get, feed_url).to_return(status: 200, body: rdf, headers: { 'Content-Type' => "#{content_type}; charset=UTF-8" })

        described_class.new.call(user: user, url: feed_url)

        source = ExternalSource.find_by!(canonical_key: feed_url)
        expect(source.protocol).to eq 'rss'
        expect(source.title).to eq 'Example RDF'
        expect(source.site_url).to eq 'https://news.example'
        expect(source.icon_hints).to eq [{ 'kind' => 'rss_image', 'url' => 'https://news.example/logo.png' }]
        resources = source.external_resources.index_by(&:title)
        expect(resources.keys).to contain_exactly('First', 'Second', 'Fragment')

        first = resources['First']
        expect(first.byline).to eq 'Ada'
        expect(first.body).to eq 'Visible'
        expect(first.body).not_to include('script')
        expect(first.canonical_url).to eq 'https://news.example/first'
        expect(first.canonical_key).to end_with('item:https://news.example/first')
        expect(first.canonical_key).not_to include(' ')
        expect(first.published_at).to eq Time.zone.parse('2026-10-26T13:33:00+09:00')

        expect(resources['Second'].body).to eq 'Summary only'
        expect(resources['Second'].published_at).to be_nil

        fragment = resources['Fragment']
        expect(fragment.canonical_url).to eq 'https://news.example/notes'
        expect(fragment.canonical_key).to include('item:https://news.example/notes#section')
        expect(ExternalStatusProjection.where(user_id: user.id).count).to eq 3
      end
    end

    it 'rejects an HTML document and unreadable XML with different errors and no shared row' do
      stub_request(:get, feed_url).to_return(status: 200, body: '<html><body>Not a feed</body></html>', headers: { 'Content-Type' => 'text/html' })
      expect { described_class.new.call(user: user, url: feed_url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }

      stub_request(:get, feed_url).to_return(status: 200, body: 'this is not xml', headers: { 'Content-Type' => 'application/xml' })
      expect { described_class.new.call(user: user, url: feed_url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
      expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
    end

    it 'stops after three redirects and does not store the feed' do
      stub_request(:get, feed_url).to_return(status: 302, headers: { 'Location' => 'https://feeds.example/1.xml' })
      stub_request(:get, 'https://feeds.example/1.xml').to_return(status: 302, headers: { 'Location' => 'https://feeds.example/2.xml' })
      stub_request(:get, 'https://feeds.example/2.xml').to_return(status: 302, headers: { 'Location' => 'https://feeds.example/3.xml' })
      stub_request(:get, 'https://feeds.example/3.xml').to_return(status: 302, headers: { 'Location' => 'https://feeds.example/4.xml' })
      stub_request(:get, 'https://feeds.example/4.xml').to_return(status: 200, body: rdf, headers: { 'Content-Type' => 'application/xml' })

      expect { described_class.new.call(user: user, url: feed_url) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'too_many_redirects' }
      expect(a_request(:get, 'https://feeds.example/4.xml')).not_to have_been_made
      expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
    end
  end
end
