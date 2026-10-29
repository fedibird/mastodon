# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::CanonicalURL do
  def normalize(value, **options)
    described_class.normalize!(value, **options)
  end

  def rejection(value, **options)
    normalize(value, **options)
    nil
  rescue ExternalBridge::Error => e
    e.code
  end

  describe 'default mode' do
    it 'keeps the existing format canonical key, case folding, and nested percent-encoding' do
      expect(normalize('https://feeds.example/listed.xml?FORMAT=RSS')).to eq 'https://feeds.example/listed.xml?format=rss'
      expect(normalize('https://feeds.example/encoded.xml?%2566ormat=%2572ss')).to eq 'https://feeds.example/encoded.xml?format=rss'
      expect(normalize('HTTPS://Feeds.EXAMPLE:443/listed.xml?format=atom#frag')).to eq 'https://feeds.example/listed.xml?format=atom'
    end

    it 'does not accept the feed-only selection parameters' do
      [
        'https://feeds.example/listed.xml?format=rss2',
        'https://feeds.example/listed.xml?format=rss_200',
        'https://feeds.example/listed.xml?format=rss_200_enc',
        'https://feeds.example/listed.xml?feed=rss2',
        'https://feeds.example/listed.xml?alt=rss',
        'https://feeds.example/listed.xml?exclude_body=1',
        'https://feeds.example/listed.xml?include_scraps=0',
        'https://feeds.example/listed.xml?all=1',
        'https://feeds.example/listed.xml?order=created',
        'https://feeds.example/listed.xml?period=weekly',
        'https://feeds.example/listed.xml?format=rss&exclude_body=1',
      ].each do |url|
        expect(rejection(url)).to eq('authenticated_source_rejected'), url
      end
    end
  end

  describe 'feed mode' do
    base = 'https://feeds.example/news'

    {
      'format' => %w(rss atom xml feed rss2 rss_200 rss_200_enc),
      'feed' => %w(rss2),
      'alt' => %w(rss),
      'exclude_body' => %w(0 1),
      'include_scraps' => %w(0 1),
      'all' => %w(0 1),
      'order' => %w(created),
      'period' => %w(weekly),
    }.each do |name, values|
      values.each do |value|
        it "accepts #{name}=#{value}" do
          expect(normalize("#{base}?#{name}=#{value}", feed: true)).to eq "#{base}?#{name}=#{value}"
        end
      end
    end

    it 'keeps a safe combination and does not rewrite pair order' do
      forward = "#{base}?format=rss_200&exclude_body=1"
      reverse = "#{base}?exclude_body=1&format=rss_200"
      expect(normalize(forward, feed: true)).to eq forward
      expect(normalize(reverse, feed: true)).to eq reverse
      expect(normalize(forward, feed: true)).not_to eq normalize(reverse, feed: true)
    end

    it 'canonicalizes case, separators, and nested encoding without moving pair boundaries again' do
      raw = 'HTTPS://Feeds.EXAMPLE:443/News.xml?FORMAT=%2572ss_200;Exclude_Body=%31#skip'
      canonical = 'https://feeds.example/News.xml?format=rss_200&exclude_body=1'
      expect(normalize(raw, feed: true)).to eq canonical
      expect(normalize(canonical, feed: true)).to eq canonical
    end

    it 'accepts six pairs and rejects a seventh' do
      six = %w(format=rss feed=rss2 alt=rss exclude_body=0 include_scraps=1 all=0)
      expect(normalize("#{base}?#{six.join('&')}", feed: true)).to eq "#{base}?#{six.join('&')}"
      expect(rejection("#{base}?#{six.join('&')}&order=created", feed: true)).to eq 'authenticated_source_rejected'
    end

    it 'rejects values outside the finite set, including later identifier parameters' do
      %w(
        format=rss3 format=daily feed=rss feed=atom alt=atom alt=rss2
        exclude_body=2 exclude_body=true include_scraps=yes all=2
        order=published period=daily period=WEEK
        tag=news channel=1 playlist=abc id=1 p=123 q=hello search=news
      ).each do |query|
        expect(rejection("#{base}?#{query}", feed: true)).to eq('authenticated_source_rejected'), query
      end
    end

    it 'rejects duplicate keys after case folding and percent-decoding' do
      [
        "#{base}?format=rss&format=atom",
        "#{base}?format=rss&FORMAT=rss",
        "#{base}?format=rss&%2566ormat=atom",
        "#{base}?Exclude_Body=1&exclude_body=0",
        "#{base}?%66ormat=rss&format=rss2",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects empty pairs, empty values, and spare separators' do
      [
        "#{base}?",
        "#{base}?format=",
        "#{base}?format",
        "#{base}?=rss",
        "#{base}?format=rss&",
        "#{base}?&format=rss",
        "#{base}?format=rss&&exclude_body=1",
        "#{base}?format=rss;",
        "#{base}?;exclude_body=1",
        "#{base}?format=rss&exclude_body=1&",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects encoded delimiters and control characters instead of splitting them into pairs' do
      [
        "#{base}?format=rss%26exclude_body%3D1",
        "#{base}?format=rss%3Bexclude_body%3D1",
        "#{base}?format=rss%3D2",
        "#{base}?format=rs%0as",
        "#{base}?exclude_body=1%00",
        "#{base}?%26exclude_body=1",
        "#{base}?format=%",
        "#{base}?format=%ZZ",
        "#{base}?format=%2",
        "#{base}?format=#{'a' * 80}",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects a known key mixed with a credential or an unknown key' do
      %w(token key auth signature sig password secret access_token api_key category preview).each do |name|
        expect(rejection("#{base}?format=rss&#{name}=SECRET", feed: true)).to eq('authenticated_source_rejected'), name
      end
      expect(rejection("#{base}?format=rss2&channel=news", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("#{base}?exclude_body=1&playlist=abc", feed: true)).to eq 'authenticated_source_rejected'
    end

    it 'rejects userinfo, private literals, and non-http schemes before a query could be kept' do
      expect(rejection('https://user:pw@feeds.example/news?format=rss2', feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection('http://127.0.0.1/news?format=rss', feed: true)).to eq 'private_address'
      expect(rejection('http://10.1.2.3/news?exclude_body=1', feed: true)).to eq 'private_address'
      expect(rejection('http://[::1]/news?period=weekly', feed: true)).to eq 'private_address'
      expect(rejection('ftp://feeds.example/news?format=rss', feed: true)).to eq 'unsupported_url'
      expect(rejection('javascript:alert(1)', feed: true)).to eq 'unsupported_url'
    end
  end

  describe 'other modes' do
    it 'does not gain the feed selection keys' do
      expect(normalize('https://cdn.example/i.png?format=rss2', asset: true)).to eq 'https://cdn.example/i.png?format=rss2'
      expect(rejection('https://cdn.example/i.png?exclude_body=1', asset: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://cdn.example/i.png?format=rss2&exclude_body=1', asset: true)).to eq 'authenticated_source_rejected'

      expect(normalize('https://feeds.example/watch?id=abc&format=rss', item: true)).to eq 'https://feeds.example/watch?id=abc&format=rss'
      expect(rejection('https://feeds.example/watch?format=rss2', item: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://feeds.example/watch?id=abc&exclude_body=1', item: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://feeds.example/watch?order=created', item: true)).to eq 'authenticated_source_rejected'
    end

    it 'keeps site links on the default rules' do
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site')).to eq 'https://example.com/site'
      expect(ExternalBridge::Presentation.normalize_url('https://feeds.example/listed.xml?format=rss')).to eq 'https://feeds.example/listed.xml?format=rss'
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?exclude_body=1')).to be_nil
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?format=rss2')).to be_nil
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?format=rss&token=SECRET')).to be_nil
    end

    it 'does not accept feed identifiers outside feed mode' do
      channel = "UC#{'0' * 22}"
      youtube = "https://www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}"
      flickr = 'https://www.flickr.com/services/feeds/photos_public.gne?tags=Cat&tagmode=any&lang=fr-fr'
      nsid = 'https://www.flickr.com/services/feeds/photos_public.gne?id=00000000000@N99'

      expect(rejection(youtube)).to eq 'authenticated_source_rejected'
      expect(rejection(flickr)).to eq 'authenticated_source_rejected'
      expect(rejection(nsid)).to eq 'authenticated_source_rejected'
      expect(rejection(youtube, asset: true)).to eq 'authenticated_source_rejected'
      expect(rejection(flickr, item: true)).to eq 'authenticated_source_rejected'
      expect(rejection(nsid, item: true)).to eq 'authenticated_source_rejected'
      expect(normalize('https://feeds.example/watch?id=abc', item: true)).to eq 'https://feeds.example/watch?id=abc'
      expect(ExternalBridge::RSS::MediaURL.normalize("https://cdn.example/a.jpg?channel_id=#{channel}")).to be_nil
      expect(ExternalBridge::RSS::MediaURL.normalize('https://cdn.example/a.jpg?tags=Cat')).to be_nil
      expect(ExternalBridge::RSS::MediaURL.normalize('https://cdn.example/a.jpg?w=100')).to eq 'https://cdn.example/a.jpg?w=100'
      expect(ExternalBridge::RSS::PosterURL.pair("https://images.example/p.jpg?channel_id=#{channel}")).to be_nil
      expect(ExternalBridge::LinkSharing::ArticleURL.normalize!('https://example.com/article?id=42')).to eq 'https://example.com/article?id=42'
      expect { ExternalBridge::LinkSharing::ArticleURL.normalize!(youtube) }.to raise_error(ExternalBridge::Error)
      expect { ExternalBridge::LinkSharing::ArticleURL.normalize!(flickr) }.to raise_error(ExternalBridge::Error)
      expect { ExternalBridge::LinkSharing::ArticleURL.normalize!(nsid) }.to raise_error(ExternalBridge::Error)
    end
  end

  describe 'host-scoped feed identifiers' do
    let(:channel) { "UC#{'0' * 22}" }
    let(:other_channel) { "UC#{'0' * 21}a" }
    let(:upper_channel) { "UC#{'0' * 21}A" }
    let(:youtube) { 'https://www.youtube.com/xml/feeds/videos.xml' }
    let(:flickr) { 'https://www.flickr.com/services/feeds/photos_public.gne' }
    let(:nsid) { '00000000000@N99' }

    def feed(value)
      normalize(value, feed: true)
    end

    it 'keeps a channel id and does not fold its case' do
      canonical = "#{youtube}?channel_id=#{channel}"
      raw = "HTTPS://WWW.YouTube.COM:443/xml/feeds/videos.xml?CHANNEL_ID=#{channel}#skip"
      expect(feed(raw)).to eq canonical
      expect(feed(canonical)).to eq canonical
      expect(feed("#{youtube}?channel_id=#{other_channel}")).not_to eq canonical
      expect(feed("#{youtube}?channel_id=#{upper_channel}")).to eq "#{youtube}?channel_id=#{upper_channel}"
      expect(feed("#{youtube}?channel_id=#{upper_channel}")).not_to eq feed("#{youtube}?channel_id=#{other_channel}")
    end

    it 'canonicalizes a nested channel id encoding once' do
      raw = "#{youtube}?%2563hannel_id=%2555C#{'0' * 22}"
      canonical = "#{youtube}?channel_id=#{channel}"
      expect(feed(raw)).to eq canonical
      expect(feed(canonical)).to eq canonical
    end

    it 'rejects a channel id outside the documented topic URL' do
      [
        "#{youtube.delete_suffix('/xml/feeds/videos.xml')}/feeds/videos.xml?channel_id=#{channel}",
        "https://youtube.com/xml/feeds/videos.xml?channel_id=#{channel}",
        "https://m.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}",
        "https://www.youtube.com./xml/feeds/videos.xml?channel_id=#{channel}",
        "https://www.youtube.com.evil.test/xml/feeds/videos.xml?channel_id=#{channel}",
        "https://notwww.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}",
        "#{youtube}/?channel_id=#{channel}",
        "#{youtube}/extra?channel_id=#{channel}",
        "https://www.youtube.com/xml/feeds/../feeds/videos.xml?channel_id=#{channel}",
        "http://www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}",
        "https://www.youtube.com:8443/xml/feeds/videos.xml?channel_id=#{channel}",
        "#{flickr}?channel_id=#{channel}",
        "https://feeds.example/news?channel_id=#{channel}",
        "#{youtube}?channel_id=uc#{'0' * 22}",
        "#{youtube}?channel_id=UC#{'0' * 21}",
        "#{youtube}?channel_id=UC#{'0' * 23}",
        "#{youtube}?channel_id=UC#{'0' * 21}.",
        "#{youtube}?playlist_id=PL#{'0' * 32}",
        "#{youtube}?user=somechannel",
        "#{youtube}?channel_id=#{channel}&format=atom",
        "#{youtube}?format=rss&channel_id=#{channel}",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'keeps flickr user ids and tag lists distinct and idempotent' do
      single = feed("#{flickr}?id=#{nsid}&tags=Cat,Dog&tagmode=ANY&lang=FR-FR")
      expect(single).to eq "#{flickr}?id=00000000000%40N99&tags=Cat%2CDog&tagmode=any&lang=fr-fr"
      expect(feed(single)).to eq single
      expect(feed("#{flickr}?tags=Cat,Dog&id=#{nsid}")).not_to eq single
      expect(feed("#{flickr}?id=00000000000@n99")).to eq "#{flickr}?id=00000000000%40n99"
      expect(feed("#{flickr}?id=00000000000@n99")).not_to eq feed("#{flickr}?id=#{nsid}")
      expect(feed("#{flickr}?tags=Cat")).not_to eq feed("#{flickr}?tags=cat")
      expect(feed("#{flickr}?tags=Cat%2CDog")).to eq "#{flickr}?tags=Cat%2CDog"
      expect(feed("#{flickr}?tags=#{'A' * 64}")).to eq "#{flickr}?tags=#{'A' * 64}"
      ten = (1..10).map { |index| "t#{index}" }
      expect(feed("#{flickr}?tags=#{ten.join(',')}")).to eq "#{flickr}?tags=#{ten.join('%2C')}"
      expect(feed("#{flickr}?id=1@N00")).to eq "#{flickr}?id=1%40N00"
      expect(feed("#{flickr}?id=#{'9' * 20}@N00")).to eq "#{flickr}?id=#{'9' * 20}%40N00"
    end

    it 'accepts documented flickr format and language tokens only on that path' do
      %w(atom_1 rss_091 rss_092 rss_100 rdf).each do |token|
        expect(feed("#{flickr}?FORMAT=#{token}")).to eq "#{flickr}?format=#{token}"
        expect(rejection("https://feeds.example/news?format=#{token}", feed: true)).to eq 'authenticated_source_rejected'
      end
      %w(de-de en-us es-us fr-fr it-it ko-kr pt-br zh-hk).each do |lang|
        expect(feed("#{flickr}?lang=#{lang}")).to eq "#{flickr}?lang=#{lang}"
      end
      expect(feed("#{flickr}?id=#{nsid}&format=atom")).to eq "#{flickr}?id=00000000000%40N99&format=atom"
      expect(feed("#{flickr}?format=rss&feed=rss2&alt=rss&exclude_body=0&include_scraps=1&all=0")).to eq(
        "#{flickr}?format=rss&feed=rss2&alt=rss&exclude_body=0&include_scraps=1&all=0"
      )
      expect(feed("#{flickr}?format=xml")).to eq "#{flickr}?format=xml"
    end

    it 'rejects unconfirmed flickr forms, broken tag lists, and mixed credentials' do
      [
        "#{flickr}?id=1",
        "#{flickr}?id=#{'9' * 21}@N00",
        "#{flickr}?id=00000000000@N0",
        "#{flickr}?id=00000000000@N001",
        "#{flickr}?id=00000000000@X99",
        "#{flickr}?ids=00000000000@N99",
        "#{flickr}?tags=",
        "#{flickr}?tags=,",
        "#{flickr}?tags=Cat,",
        "#{flickr}?tags=,Cat",
        "#{flickr}?tags=Cat,,Dog",
        "#{flickr}?tags=Cat,Dog,",
        "#{flickr}?tags=#{'A' * 65}",
        "#{flickr}?tags=#{(1..11).map { |index| "t#{index}" }.join(',')}",
        "#{flickr}?tags=Cat+Dog",
        "#{flickr}?tags=Cat%2BDog",
        "#{flickr}?tags=Cat%20Dog",
        "#{flickr}?tags=%E6%9D%B1%E4%BA%AC",
        "#{flickr}?tags=100%25",
        "#{flickr}?tags=Cat%26Dog",
        "#{flickr}?tagmode=all",
        "#{flickr}?tagmode=maybe&tags=Cat",
        "#{flickr}?id=#{nsid}&tagmode=any",
        "#{flickr}?lang=ja",
        "#{flickr}?lang=en",
        "#{flickr}?format=json",
        "#{flickr}?format=php",
        "#{flickr}?format=cdf",
        "#{flickr}?id=#{nsid}&format=xml",
        "#{flickr}?id=#{nsid}&format=feed",
        "#{flickr}?id=#{nsid}&exclude_body=1",
        "#{flickr}?format=atom_1&exclude_body=1",
        "#{flickr}?tags=Cat&token=SECRET",
        "https://api.flickr.com/services/feeds/photos_public.gne?id=#{nsid}",
        "https://flickr.com/services/feeds/photos_public.gne?tags=Cat",
        "https://www.flickr.com.evil.test/services/feeds/photos_public.gne?tags=Cat",
        'https://www.flickr.com/services/feeds/photos_friends.gne?tags=Cat',
        "http://www.flickr.com/services/feeds/photos_public.gne?tags=Cat",
        "https://www.flickr.com:8443/services/feeds/photos_public.gne?tags=Cat",
        "https://user:pw@www.flickr.com/services/feeds/photos_public.gne?id=#{nsid}",
        "#{flickr}?id=#{nsid}&id=00000000000@n99",
        "#{flickr}?tags=Cat&TAGS=Dog",
        "#{flickr}?lang=en-us&%6cang=fr-fr",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects delimiter smuggling, a seventh pair, and an overlong feed URL' do
      expect(rejection("#{youtube}?channel_id=#{channel}%26token%3DSECRET", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("#{flickr}?tags=Cat%3Btagmode%3Dany", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("#{youtube}?channel_id=#{channel}&channel_id=#{other_channel}", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("#{youtube}?channel_id=#{channel}&%63hannel_id=#{other_channel}", feed: true)).to eq 'authenticated_source_rejected'
      six = %w(format=rss feed=rss2 alt=rss exclude_body=0 include_scraps=1 all=0)
      expect(rejection("https://feeds.example/news?#{six.join('&')}&order=created", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("https://feeds.example/#{'n' * 2_100}?format=rss", feed: true)).to eq 'unsupported_url'
      expect(rejection("https://user:pw@www.youtube.com/xml/feeds/videos.xml?channel_id=#{channel}", feed: true)).to eq 'authenticated_source_rejected'
    end
  end
end
