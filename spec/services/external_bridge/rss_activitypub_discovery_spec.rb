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
      expect(feed.items.first.activitypub_explicit).to be true
      expect(feed.items.first.activitypub_url).to eq 'https://posts.example/users/alice/statuses/123'
    end

    it 'keeps RSS 2.0, RDF RSS 1.0 and ordinary feeds merely as URL candidates' do
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
        expect(feed.items.first.activitypub_url).to match(%r{\Ahttps://news\.example/})
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
      expect(@result.object_type).to eq 'Note'
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
      expect(resource.activitypub_checked_at).to be_present
      expect(resource.activitypub_next_check_at).to be > Time.current
      expect(source.reload.activitypub_state).to eq 'verified'
      expect(source.activitypub_instance_state).to eq 'verified'
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
      expect(source.activitypub_state).to eq 'items_verified'
    end

    it 'distinguishes NodeInfo present but not advertising ActivityPub' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url)
      ExternalSubscription.create!(user: user, external_source: source)
      public_nodeinfo('https://feeds.example', protocols: ['diaspora'])
      described_class.new.call(source.id)
      expect(source.reload.activitypub_instance_state).to eq 'not_advertised'
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
      expect(resource.activitypub_state).to eq 'unknown'
      expect(resource.activitypub_object_id).to be_nil
      expect(resource.activitypub_next_check_at).to be_nil
      expect(source.reload.activitypub_state).to eq 'unknown'
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
  end
end
