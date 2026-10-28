# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'RSS ActivityPub discovery' do
  let(:url) { 'https://posts.example/@alice/123' }
  let(:object) do
    {
      '@context' => ['https://www.w3.org/ns/activitystreams'],
      'id' => 'https://posts.example/users/alice/statuses/123',
      'type' => 'Note',
      'attributedTo' => 'https://posts.example/users/alice',
    }
  end

  before do
    redis.keys('external_bridge:rss_ap:host:*').each { |key| redis.del(key) }
  end

  def public_object(url = self.url, data = object)
    stub_request(:get, url)
      .with { |request| request.headers['Accept'].to_s.include?('application/ld+json') }
      .to_return(status: 200, body: data.to_json, headers: { 'Content-Type' => 'application/activity+json' })
  end

  def public_nodeinfo(origin = 'https://feeds.example', protocols: ['activitypub'])
    stub_request(:get, "#{origin}/.well-known/nodeinfo").to_return(
      status: 200,
      body: { links: [{ rel: 'http://nodeinfo.diaspora.software/ns/schema/2.1', href: "#{origin}/nodeinfo/2.1" }] }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    stub_request(:get, "#{origin}/nodeinfo/2.1").to_return(
      status: 200,
      body: { version: '2.1', software: { name: 'mastodon', version: '4.2.0' }, protocols: protocols }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
  end

  describe ExternalBridge::RSS::Parser do
    it 'recognizes an Atom generator and prefers an explicit AP alternate to the HTML link' do
      xml = <<~XML
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Alice</title><generator>Mastodon</generator>
          <entry><id>urn:123</id><title>Hello</title>
            <link rel="alternate" type="text/html" href="https://posts.example/@alice/123"/>
            <link rel="alternate" type="application/activity+json" href="https://posts.example/users/alice/statuses/123"/>
          </entry>
        </feed>
      XML
      feed = described_class.parse!(xml)
      expect(feed.activitypub_hint).to be true
      expect(feed.activitypub_generator_hint).to be true
      expect(feed.items.first.activitypub_explicit).to be true
      expect(feed.items.first.activitypub_url).to eq 'https://posts.example/users/alice/statuses/123'
      expect(feed.items.first.activitypub_sample_url).to be_nil
    end

    it 'keeps ordinary RSS 2.0 and RDF links as sample inputs, not typed AP candidates' do
      rss = '<rss><channel><title>news</title><item><guid>guid-1</guid><link>https://news.example/1</link></item></channel></rss>'
      rdf = <<~XML
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
          <channel><title>RDF</title></channel>
          <item rdf:about="https://news.example/2"><title>Two</title></item>
        </rdf:RDF>
      XML
      [rss, rdf].each do |xml|
        feed = described_class.parse!(xml)
        expect(feed.activitypub_hint).to be false
        expect(feed.activitypub_generator_hint).to be false
        expect(feed.items.first.activitypub_explicit).to be false
        expect(feed.items.first.activitypub_url).to be_nil
        expect(feed.items.first.activitypub_sample_url).to match(%r{\Ahttps://news\.example/})
      end
    end

    it 'rejects credentialled or private candidate URLs' do
      feed = described_class.parse!(<<~XML)
        <feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>
          <entry><id>urn:1</id><title>B</title>
            <link rel="alternate" type="application/activity+json" href="http://127.0.0.1/secret"/>
            <link rel="alternate" type="text/html" href="https://posts.example/e?token=secret"/>
          </entry>
        </feed>
      XML
      expect(feed.items.first.activitypub_url).to be_nil
      expect(feed.items.first.activitypub_explicit).to be false
    end
  end

  describe ExternalBridge::RSS::ActivityPub::Probe do
    it 'verifies an ActivityStreams object without importing it as a Status' do
      public_object
      expect { @result = described_class.new.call(url) }.not_to change(Status, :count)
      expect(@result.state).to eq 'verified'
      expect(@result.object_id).to eq 'https://posts.example/users/alice/statuses/123'
      expect(@result.object_id_status).to eq 'self_reported'
      expect(@result.object_type).to eq 'Note'
      expect(a_request(:get, @result.object_id)).not_to have_been_made
    end

    it 'keeps a self-reported id that differs from the fetch URL, including fragment and query' do
      identifier = 'https://posts.example/users/alice/statuses/123?page=2#main'
      public_object(url, object.merge('id' => identifier))
      result = described_class.new.call(url)
      expect(result.state).to eq 'verified'
      expect(result.object_id).to eq identifier
      expect(result.object_id_status).to eq 'self_reported'
      expect(a_request(:get, identifier)).not_to have_been_made
    end

    it 'stores a syntactically safe id from another host without dereferencing it' do
      identifier = 'https://attacker.example/users/alice/statuses/999'
      stub_request(:get, identifier).to_return(status: 200, body: object.to_json, headers: { 'Content-Type' => 'application/activity+json' })
      public_object(url, object.merge('id' => identifier))
      result = described_class.new.call(url)
      expect(result.state).to eq 'verified'
      expect(result.object_id).to eq identifier
      expect(result.object_id_status).to eq 'self_reported'
      expect(a_request(:get, identifier)).not_to have_been_made
    end

    it 'does not keep a credentialled, private, or non-URI object id' do
      bad_ids = [
        'https://user:pass@posts.example/secret',
        'http://127.0.0.1/obj',
        'javascript:alert(1)',
        'https://posts.example/obj?viewkey=secret',
        'not a uri',
        "https://posts.example/#{'a' * 3_000}",
      ]
      bad_ids.each do |identifier|
        public_object(url, object.merge('id' => identifier))
        result = described_class.new.call(url)
        expect(result.state).to eq('unavailable'), identifier
        expect(result.object_id).to be_nil
      end
    end

    it 'does not accept HTML, an actor, or a JSON object lacking the AS2 context' do
      stub_request(:get, url).to_return(status: 200, body: object.to_json, headers: { 'Content-Type' => 'text/html' })
      expect(described_class.new.call(url).state).to eq 'unavailable'

      public_object(url, object.merge('type' => 'Person'))
      expect(described_class.new.call(url).state).to eq 'unavailable'

      public_object(url, object.except('@context'))
      expect(described_class.new.call(url).state).to eq 'unavailable'
    end

    it 'distinguishes inaccessible from unavailable and refuses SSRF before a request' do
      stub_request(:get, url).to_return(status: 401)
      expect(described_class.new.call(url).state).to eq 'inaccessible'
      stub_request(:get, url).to_return(status: 404)
      expect(described_class.new.call(url).state).to eq 'unavailable'

      stub_request(:get, 'http://127.0.0.1/private').to_return(status: 200, body: object.to_json)
      expect(described_class.new.call('http://127.0.0.1/private').state).to eq 'error'
      expect(a_request(:get, 'http://127.0.0.1/private')).not_to have_been_made
    end

    it 'rejects an item URL carrying a video viewkey before making a new AP request' do
      unsafe = 'https://posts.example/clip?viewkey=secret'
      stub_request(:get, unsafe).to_return(status: 200, body: object.to_json)
      expect(described_class.new.call(unsafe).state).to eq 'error'
      expect(a_request(:get, unsafe)).not_to have_been_made
    end

    it 'charges a shared redirect destination before each cross-origin hop' do
      destination = 'https://collector.example/objects/1'
      stub_request(:get, destination).to_return(
        status: 200,
        body: object.to_json,
        headers: { 'Content-Type' => 'application/activity+json' }
      )
      budget = ExternalBridge::RSS::HttpClient::ACTIVITYPUB_PROFILE.budget
      origins = Array.new(budget + 1) { |index| "https://origin-#{index}.example/items/1" }
      origins.each do |origin|
        stub_request(:get, origin).to_return(status: 302, headers: { 'Location' => destination })
      end

      origins.first(budget).each do |origin|
        expect(described_class.new.call(origin).state).to eq 'verified'
      end
      expect(described_class.new.call(origins.last).state).to eq 'error'
      expect(origins.size).to be > 2
      expect(request_count(destination)).to eq budget
    end

    it 'refuses an HTTP redirect to a private address' do
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => 'http://127.0.0.1/private' })
      stub_request(:get, 'http://127.0.0.1/private').to_return(status: 200, body: object.to_json)
      expect(described_class.new.call(url).state).to eq 'error'
      expect(a_request(:get, 'http://127.0.0.1/private')).not_to have_been_made
    end
  end

  describe ExternalBridge::RSS::ActivityPub::ProbeSource do
    let(:user) { Fabricate(:user) }
    let(:feed_url) { 'https://feeds.example/news.xml' }

    before do
      enable_external_bridge_rss!(user)
      Setting.external_bridge_rss_activitypub_discovery = true
    end

    it 'stores per-item evidence, promotes the source, and preserves the private projection contract' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, activitypub_hint: true)
      ExternalSubscription.create!(user: user, external_source: source)
      resource = ExternalResource.create!(external_source: source, protocol: 'rss',
                                        canonical_key: "feed:#{feed_url}\nitem:123",
                                        canonical_url: url, activitypub_candidate_url: url)
      public_object
      public_nodeinfo

      described_class.new.call(source.id)

      expect(resource.reload.activitypub_state).to eq 'verified'
      expect(resource.activitypub_object_id).to eq object['id']
      expect(resource.activitypub_object_id_status).to eq 'self_reported'
      expect(resource.activitypub_checked_at).to be_present
      expect(resource.activitypub_next_check_at).to be > Time.current
      expect(source.reload.activitypub_state).to eq 'items_verified'
      expect(source.activitypub_instance_state).to eq 'advertised'
      expect(source.host_activitypub_supported).to eq 'supported'
      expect(source.activitypub_feed_attribution).to eq 'unknown'
      expect(source.activitypub_software).to eq 'mastodon'
      expect(ExternalStatusProjection.count).to eq 0

      described_class.new.call(source.id)
      expect(a_request(:get, url)).to have_been_made.once
    end

    it 'does not conclude an RSS aggregator is an AP server merely because its items are' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      resource = ExternalResource.create!(external_source: source, protocol: 'rss',
                                        canonical_key: 'foreign-entry', activitypub_candidate_url: url)
      stub_request(:get, "https://feeds.example/.well-known/nodeinfo").to_return(status: 404)
      public_object

      described_class.new.call(source.id)

      expect(resource.reload.activitypub_state).to eq 'verified'
      expect(source.reload.activitypub_instance_state).to eq 'unavailable'
      expect(source.host_activitypub_supported).to eq 'unknown'
      expect(source.activitypub_feed_attribution).to eq 'unknown'
      expect(source.activitypub_state).to eq 'items_verified'
    end

    it 'distinguishes NodeInfo present but not advertising ActivityPub' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      public_nodeinfo('https://feeds.example', protocols: ['diaspora'])
      described_class.new.call(source.id)
      expect(source.reload.activitypub_instance_state).to eq 'not_advertised'
      expect(source.host_activitypub_supported).to eq 'not_advertised'
      expect(source.activitypub_feed_attribution).to eq 'unknown'
      expect(source.activitypub_state).to eq 'unknown'
    end

    it 'forgets a verified object when the same GUID starts pointing to a different URL' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      response = ExternalBridge::RSS::Response.new(code: 200)
      feed = lambda do |link|
        ExternalBridge::RSS::Parser.parse!(<<~XML)
          <rss><channel><title>Example</title>
            <item><guid>stable-guid</guid><title>Post</title><link>#{link}</link></item>
          </channel></rss>
        XML
      end
      ingest = ExternalBridge::RSS::Ingest.new
      ingest.apply_public!(source, feed.call(url), response)
      resource = source.external_resources.first
      resource.update!(activitypub_state: 'verified', activitypub_object_id: object['id'],
                       activitypub_object_type: 'Note', activitypub_checked_at: Time.current,
                       activitypub_next_check_at: 7.days.from_now)

      ingest.apply_public!(source, feed.call('https://posts.example/@alice/124'), response)

      expect(resource.reload.activitypub_candidate_url).to eq 'https://posts.example/@alice/124'
      expect(resource.activitypub_candidate_digest).to eq Digest::SHA256.hexdigest('https://posts.example/@alice/124')
      expect(resource.activitypub_state).to eq 'unknown'
      expect(resource.activitypub_object_id).to be_nil
      expect(resource.activitypub_object_id_status).to be_nil
      expect(resource.activitypub_evidence_version).to be > 0
      expect(resource.activitypub_next_check_at).to be <= Time.current
      expect(source.reload.activitypub_state).to eq 'unknown'
      expect(source.activitypub_feed_attribution).to eq 'unknown'
    end

    it 'leaves sources and resources alone when opt-in probing is disabled' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      resource = ExternalResource.create!(external_source: source, protocol: 'rss',
                                        canonical_key: 'entry-one', activitypub_candidate_url: url)
      Setting.external_bridge_rss_activitypub_discovery = false
      described_class.new.call(source.id)
      expect(resource.reload.activitypub_state).to eq 'unknown'
      expect(resource.activitypub_checked_at).to be_nil
    end

    it 'probes explicit links before ordinary ones and still pauses ordinary sampling after a verified item' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      explicit = Array.new(3) do |index|
        create_candidate(source, "explicit-#{index}", "https://posts.example/ap/#{index}", explicit: true)
      end
      ordinary = Array.new(6) do |index|
        create_candidate(source, "ordinary-#{index}", "https://news.example/p/#{index}", explicit: false)
      end
      explicit.each { |item| public_object(item.activitypub_candidate_url) }
      ordinary.each do |item|
        stub_request(:get, item.activitypub_candidate_url).to_return(status: 404, headers: { 'Content-Type' => 'text/html' })
      end
      stub_request(:get, 'https://feeds.example/.well-known/nodeinfo').to_return(status: 404)

      described_class.new.call(source.id)
      described_class.new.call(source.id)

      expect(explicit.sum { |item| request_count(item.activitypub_candidate_url) }).to eq 3
      expect(ordinary.sum { |item| request_count(item.activitypub_candidate_url) }).to eq 1
      expect(source.reload.activitypub_ordinary_blocked_until).to be > Time.current
      expect(source.activitypub_state).to eq 'items_verified'
      expect(source.host_activitypub_supported).to eq 'unknown'
      expect(source.activitypub_fresh_items_allowed?).to be false
    end

    it 'pauses ordinary sampling on 401 without marking the feed non-AP' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      stub_request(:get, 'https://feeds.example/.well-known/nodeinfo').to_return(status: 404)
      rows = Array.new(2) do |index|
        create_candidate(source, "locked-#{index}", "https://news.example/private/#{index}", explicit: false)
      end
      rows.each do |row|
        stub_request(:get, row.activitypub_candidate_url).to_return(status: 401, headers: { 'Content-Type' => 'text/html' })
      end

      described_class.new.call(source.id)

      fetched = rows.select { |row| request_count(row.activitypub_candidate_url) == 1 }
      skipped = rows.select { |row| request_count(row.activitypub_candidate_url).zero? }
      expect(fetched.size).to eq 1
      expect(skipped.size).to eq 1
      expect(fetched.first.reload.activitypub_state).to eq 'inaccessible'
      expect(skipped.first.reload.activitypub_checked_at).to be_nil
      expect(source.reload.activitypub_ordinary_blocked_until).to be > Time.current
      expect(source.host_activitypub_supported).to eq 'unknown'
      expect(source.activitypub_instance_state).not_to eq 'not_advertised'
      expect(source.activitypub_state).to eq 'unknown'

      typed = create_candidate(source, 'typed-later', 'https://posts.example/users/alice/statuses/401', explicit: true)
      public_object(typed.activitypub_candidate_url)
      described_class.new.call(source.id)

      expect(request_count(typed.activitypub_candidate_url)).to eq 1
      expect(request_count(skipped.first.activitypub_candidate_url)).to eq 0
      expect(skipped.first.reload.activitypub_state).to eq 'unknown'
    end

    it 'does not widen ordinary GETs because one remote item was ActivityStreams' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://news.example/feed.xml')
      ExternalSubscription.create!(user: user, external_source: source)
      stub_request(:get, 'https://news.example/.well-known/nodeinfo').to_return(status: 404)
      ExternalResource.create!(
        external_source: source, protocol: 'rss', canonical_key: 'remote-ap',
        activitypub_candidate_url: 'https://posts.example/users/alice/statuses/9',
        activitypub_state: 'verified', activitypub_object_id: 'https://posts.example/users/alice/statuses/9',
        activitypub_object_id_status: 'self_reported', activitypub_object_type: 'Note',
        activitypub_checked_at: Time.current, activitypub_next_check_at: 7.days.from_now,
        activitypub_explicit: false
      )
      ingest = ExternalBridge::RSS::Ingest.new
      links = (1..8).map { |index| ["story-#{index}", "https://news.example/story/#{index}"] }
      ingest.apply_public!(source, rss_feed(rss_items(links)), ExternalBridge::RSS::Response.new(code: 200))

      expect(source.reload.activitypub_fresh_items_allowed?).to be false
      expect(source.activitypub_feed_attribution).to eq 'unknown'
      queued = ExternalBridge::RSS::ActivityPub::SampleBudget.outstanding_ordinary(source)
      expect(queued.count).to eq ExternalBridge::RSS::ActivityPub::Limits::ORDINARY_SAMPLE_CAP
      queued.each do |row|
        stub_request(:get, row.activitypub_candidate_url).to_return(status: 404, headers: { 'Content-Type' => 'text/html' })
      end

      described_class.new.call(source.id)

      expect(queued.sum { |row| request_count(row.activitypub_candidate_url) }).to eq 1
      expect(source.reload.activitypub_ordinary_blocked_until).to be > Time.current
      expect(source.external_resources.find_by!(canonical_key: 'remote-ap').activitypub_state).to eq 'verified'
      expect(source.host_activitypub_supported).to eq 'unknown'
    end

    it 'does not open the fresh ordinary budget from one same-host verified permalink' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://news.example/mixed.xml')
      ExternalResource.create!(
        external_source: source, protocol: 'rss', canonical_key: 'same-host-ap',
        activitypub_candidate_url: 'https://news.example/story/old',
        activitypub_state: 'verified', activitypub_object_id: 'https://news.example/story/old',
        activitypub_object_id_status: 'self_reported', activitypub_object_type: 'Note',
        activitypub_checked_at: Time.current, activitypub_next_check_at: 7.days.from_now,
        activitypub_explicit: false
      )
      links = (1..6).map { |index| ["local-#{index}", "https://news.example/story/#{index}"] }
      ExternalBridge::RSS::Ingest.new.apply_public!(source, rss_feed(rss_items(links)), ExternalBridge::RSS::Response.new(code: 200))

      expect(source.reload.activitypub_fresh_items_allowed?).to be false
      expect(ExternalBridge::RSS::ActivityPub::SampleBudget.outstanding_ordinary(source).count).to eq ExternalBridge::RSS::ActivityPub::Limits::ORDINARY_SAMPLE_CAP
    end

    it 'reclaims exploration slots for later permalinks after the negative cooldown' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://news.example/feed.xml')
      ExternalSubscription.create!(user: user, external_source: source)
      ingest = ExternalBridge::RSS::Ingest.new
      response = ExternalBridge::RSS::Response.new(code: 200)
      stub_request(:get, 'https://news.example/.well-known/nodeinfo').to_return(status: 404)
      links = (1..6).map { |index| ["g#{index}", "https://news.example/#{index}"] }
      ingest.apply_public!(source, rss_feed(rss_items(links.first(4))), response)

      sampled = source.external_resources.where.not(activitypub_candidate_url: nil).pluck(:activitypub_candidate_url)
      expect(sampled.size).to eq ExternalBridge::RSS::ActivityPub::Limits::ORDINARY_SAMPLE_CAP
      sampled.each { |candidate| stub_request(:get, candidate).to_return(status: 404, headers: { 'Content-Type' => 'text/html' }) }

      described_class.new.call(source.id)

      expect(request_count('https://news.example/1')).to eq 1
      expect(request_count('https://news.example/2')).to eq 0
      expect(resource_for(source, 'g1').activitypub_checked_at).to be_present
      expect(resource_for(source, 'g2').activitypub_checked_at).to be_nil
      expect(source.reload.activitypub_ordinary_blocked_until).to be > Time.current
      ingest.apply_public!(source, rss_feed(rss_items(links)), response)
      expect(source.external_resources.where.not(activitypub_candidate_url: nil).pluck(:activitypub_candidate_url)).to match_array(sampled)

      source.update!(activitypub_ordinary_blocked_until: 1.hour.ago)
      ingest.apply_public!(source, rss_feed(rss_items(links)), response)
      expect(resource_for(source, 'g3').activitypub_candidate_url).to eq 'https://news.example/3'
      expect(resource_for(source, 'g4').activitypub_candidate_url).to be_nil
      expect(resource_for(source, 'g5').activitypub_candidate_url).to be_nil
      stub_request(:get, 'https://news.example/3').to_return(status: 404, headers: { 'Content-Type' => 'text/html' })

      described_class.new.call(source.id)

      expect(request_count('https://news.example/1')).to eq 1
      expect(request_count('https://news.example/2')).to eq 1
      expect(request_count('https://news.example/3')).to eq 0
    end

    it 'queues newer ordinary permalinks once checked rows release their slots' do
      feed_key = 'https://posts.example/users/alice.rss'
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_key)
      ExternalSubscription.create!(user: user, external_source: source)
      ingest = ExternalBridge::RSS::Ingest.new
      response = ExternalBridge::RSS::Response.new(code: 200)
      stub_request(:get, 'https://posts.example/.well-known/nodeinfo').to_return(status: 404)
      early = (1..10).map { |index| ["p#{index}", "https://posts.example/@alice/#{index}"] }
      ingest.apply_public!(source, rss_feed(rss_items(early), generator: 'Mastodon v4.2.0'), response)

      expect(source.reload.activitypub_feed_attribution).to eq 'likely'
      expect(source.external_resources.where.not(activitypub_candidate_url: nil).count).to eq ExternalBridge::RSS::ActivityPub::Limits::CONFIRMED_HOST_SAMPLE_CAP
      source.external_resources.where.not(activitypub_candidate_url: nil).update_all(
        activitypub_checked_at: Time.current,
        activitypub_next_check_at: 7.days.from_now,
        activitypub_state: 'unavailable'
      )

      later = early + (11..14).map { |index| ["p#{index}", "https://posts.example/@alice/#{index}"] }
      ingest.apply_public!(source, rss_feed(rss_items(later), generator: 'Mastodon v4.2.0'), response)
      fresh = source.external_resources.where(activitypub_checked_at: nil).where.not(activitypub_candidate_url: nil)
      expect(fresh.count).to eq 6
      (11..14).each do |index|
        expect(resource_for(source, "p#{index}").activitypub_candidate_url).to eq "https://posts.example/@alice/#{index}"
      end
      fresh.each { |row| public_object(row.activitypub_candidate_url) }

      described_class.new.call(source.id)

      expect(fresh.sum { |row| request_count(row.activitypub_candidate_url) }).to eq ExternalBridge::RSS::ActivityPub::Limits::MAX_GETS_PER_RUN
      expect(source.reload.activitypub_ordinary_blocked_until).to be_nil
      expect(source.activitypub_feed_attribution).to eq 'likely'
    end

    it 'does not GET every ordinary permalink on a host that advertises ActivityPub' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, host_activitypub_supported: 'supported')
      ExternalSubscription.create!(user: user, external_source: source)
      rows = Array.new(12) do |index|
        create_candidate(source, "recent-#{index}", "https://feeds.example/users/alice/statuses/#{index}", explicit: false)
      end
      rows.each { |item| public_object(item.activitypub_candidate_url) }
      public_nodeinfo

      described_class.new.call(source.id)

      expect(rows.sum { |item| request_count(item.activitypub_candidate_url) }).to eq ExternalBridge::RSS::ActivityPub::Limits::MAX_GETS_PER_RUN
      expect(source.reload.host_activitypub_supported).to eq 'supported'
      expect(source.activitypub_feed_attribution).to eq 'unknown'
      expect(source.activitypub_state).to eq 'items_verified'
    end
  end

  describe ExternalBridge::RSS::Ingest do
    it 'attributes a feed only from generator plus same-host entry identity' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://posts.example/users/alice.rss')
      response = ExternalBridge::RSS::Response.new(code: 200)
      attributed = ExternalBridge::RSS::Parser.parse!(<<~XML)
        <rss><channel><title>Alice</title><generator>Mastodon v4.2.0</generator>
          <item><guid>tag:posts.example,2026:1</guid><link>https://posts.example/@alice/1</link><title>Hi</title></item>
        </channel></rss>
      XML
      described_class.new.apply_public!(source, attributed, response)
      expect(source.reload.activitypub_generator_hint).to be true
      expect(source.activitypub_feed_attribution).to eq 'likely'
      expect(source.host_activitypub_supported).to eq 'unknown'
      expect(source.activitypub_state).to eq 'hinted'
      expect(source.external_resources.where.not(activitypub_candidate_url: nil).count).to eq 1

      off_host = ExternalBridge::RSS::Parser.parse!(<<~XML)
        <rss><channel><title>Alice</title><generator>Mastodon v4.2.0</generator>
          <item><guid>foreign</guid><link>https://other.example/post</link><title>Away</title></item>
        </channel></rss>
      XML
      other = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://posts.example/mirror.xml')
      described_class.new.apply_public!(other, off_host, response)
      expect(other.reload.activitypub_generator_hint).to be true
      expect(other.activitypub_feed_attribution).to eq 'unknown'
    end

    it 'stores only a capped ordinary sample and every explicit link' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://news.example/feed.xml')
      items = Array.new(20) do |index|
        %(<item><guid>g#{index}</guid><link>https://news.example/#{index}</link><title>T#{index}</title></item>)
      end
      explicit = %(<item><guid>typed</guid><title>Typed</title><link>https://news.example/html</link><link rel="alternate" type="application/activity+json" href="https://news.example/users/alice/statuses/9"/></item>)
      feed = ExternalBridge::RSS::Parser.parse!("<rss><channel><title>News</title>#{items.join}#{explicit}</channel></rss>")
      described_class.new.apply_public!(source, feed, ExternalBridge::RSS::Response.new(code: 200))

      resources = source.external_resources
      expect(resources.where(activitypub_explicit: true).count).to eq 1
      expect(resources.where(activitypub_explicit: false).where.not(activitypub_candidate_url: nil).count).to eq ExternalBridge::RSS::ActivityPub::Limits::ORDINARY_SAMPLE_CAP
      expect(resources.where(activitypub_candidate_url: nil).count).to eq 18
    end
  end

  describe ExternalBridge::RSS::ActivityPub::NodeInfoProbe do
    it 'does not follow a cross-origin redirect' do
      stub_request(:get, 'https://feeds.example/.well-known/nodeinfo').to_return(
        status: 302, headers: { 'Location' => 'https://collector.example/nodeinfo' }
      )
      stub_request(:get, 'https://collector.example/nodeinfo').to_return(
        status: 200,
        body: { protocols: ['activitypub'], software: { name: 'mastodon' } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      expect(described_class.new.call('https://feeds.example/news.xml').state).to eq 'error'
      expect(a_request(:get, 'https://collector.example/nodeinfo')).not_to have_been_made
    end

    it 'follows a same-origin redirect and still refuses a later cross-origin hop' do
      stub_request(:get, 'https://feeds.example/.well-known/nodeinfo').to_return(
        status: 302, headers: { 'Location' => 'https://feeds.example/nodeinfo/discovery' }
      )
      stub_request(:get, 'https://feeds.example/nodeinfo/discovery').to_return(
        status: 200,
        body: { links: [{ rel: 'http://nodeinfo.diaspora.software/ns/schema/2.0', href: 'https://evil.example/nodeinfo/2.0' }] }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      stub_request(:get, 'https://evil.example/nodeinfo/2.0').to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      expect(described_class.new.call('https://feeds.example/news.xml').state).to eq 'error'
      expect(a_request(:get, 'https://feeds.example/nodeinfo/discovery')).to have_been_made.once
      expect(a_request(:get, 'https://evil.example/nodeinfo/2.0')).not_to have_been_made
    end
  end

  def rss_items(pairs)
    pairs.map { |guid, link| %(<item><guid>#{guid}</guid><link>#{link}</link><title>#{guid}</title></item>) }.join
  end

  def rss_feed(items_xml, generator: nil)
    generator_xml = generator ? "<generator>#{generator}</generator>" : ''
    ExternalBridge::RSS::Parser.parse!("<rss><channel><title>Feed</title>#{generator_xml}#{items_xml}</channel></rss>")
  end

  def resource_for(source, guid)
    source.external_resources.find_by!(canonical_key: "feed:#{source.canonical_key}\nitem:#{guid}")
  end

  def create_candidate(source, key, candidate, explicit:)
    ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: key,
      canonical_url: candidate,
      activitypub_candidate_url: candidate,
      activitypub_explicit: explicit,
      published_at: Time.current
    )
  end

  def request_count(candidate)
    WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:get, candidate))
  end
end
