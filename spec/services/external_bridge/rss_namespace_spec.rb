# frozen_string_literal: true

require 'rails_helper'

# Synthetic documents only. Namespace URIs decide which element is read.
# Prefix spelling and document order must not change the stored URLs.
RSpec.describe ExternalBridge::RSS::Parser do
  def atom_self(href, prefix: 'atom')
    %(<#{prefix}:link xmlns:#{prefix}="http://www.w3.org/2005/Atom" rel="self" href="#{href}" type="application/rss+xml"/>)
  end

  def rss2(channel_links:, item_links:)
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0">
        <channel>
          #{channel_links}
          <title>Namespace News</title>
          <item>
            <guid>story-1</guid>
            <title>Story</title>
            #{item_links}
            <description><![CDATA[<img src="photo.png" alt="Relative">]]></description>
          </item>
        </channel>
      </rss>
    XML
  end

  def parse_rss2(self_first:, prefix: 'atom')
    self_link = atom_self('https://feeds.example/namespace.xml', prefix: prefix)
    site = '<link>https://news.example/</link>'
    item_self = atom_self('https://feeds.example/namespace.xml#item', prefix: prefix)
    item_link = '<link>https://news.example/posts/1</link>'
    described_class.parse!(rss2(
                             channel_links: self_first ? "#{self_link}#{site}" : "#{site}#{self_link}",
                             item_links: self_first ? "#{item_self}#{item_link}" : "#{item_link}#{item_self}"
                           ))
  end

  describe 'RSS 2.0 link and atom:link' do
    it 'keeps the site and article URLs when atom:link self is before or after the RSS link' do
      [true, false].each do |self_first|
        feed = parse_rss2(self_first: self_first)
        item = feed.items.first

        expect(feed.site_url).to eq 'https://news.example'
        expect(item.canonical_url).to eq 'https://news.example/posts/1'
        expect(item.key).to eq 'story-1'
        expect(item.activitypub_explicit).to be false
        expect(item.activitypub_sample_url).to eq 'https://news.example/posts/1'
        expect(item.media.map { |row| row['url'] }).to eq ['https://news.example/posts/photo.png']
      end
    end

    it 'treats an arbitrary Atom prefix as the same URI' do
      early = parse_rss2(self_first: true, prefix: 'a')
      late = parse_rss2(self_first: false, prefix: 'z')

      expect(early.site_url).to eq late.site_url
      expect(early.items.first.canonical_url).to eq late.items.first.canonical_url
      expect(early.site_url).to eq 'https://news.example'
    end
  end

  it 'does not let another namespace replace RSS 2.0 fields, media, or iTunes metadata' do
    feed = described_class.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:content="http://purl.org/rss/1.0/modules/content/"
           xmlns:media="http://search.yahoo.com/mrss/"
           xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
           xmlns:ex="https://foreign.example/ns">
        <channel>
          <ex:title>Foreign channel</ex:title>
          <ex:link>https://evil.example/channel</ex:link>
          <title>Real channel</title>
          <link>https://news.example/</link>
          <ex:image href="https://cdn.example/evil.jpg"/>
          <image><ex:url>https://cdn.example/evil.png</ex:url><url>https://cdn.example/rss.png</url></image>
          <itunes:image href="https://cdn.example/cover.jpg"/>
          <item>
            <ex:guid>foreign-guid</ex:guid>
            <guid>real-guid</guid>
            <ex:title>Foreign story</ex:title>
            <title>Real story</title>
            <ex:link>https://evil.example/story</ex:link>
            <link>https://news.example/watch?id=abc123</link>
            <ex:creator>Eve</ex:creator>
            <ex:author>Mallory</ex:author>
            <dc:creator>Ada</dc:creator>
            <author>Grace</author>
            <ex:pubDate>Wed, 01 Jan 2020 00:00:00 GMT</ex:pubDate>
            <ex:date>1999-01-01T00:00:00Z</ex:date>
            <pubDate>Thu, 02 Jan 2020 03:04:05 GMT</pubDate>
            <ex:encoded>Wrong encoded</ex:encoded>
            <ex:description>Wrong description</ex:description>
            <description>Summary only</description>
            <content:encoded><![CDATA[<p>Encoded body</p>]]></content:encoded>
            <ex:content url="https://cdn.example/evil.mp4" type="video/mp4"/>
            <media:content url="https://cdn.example/clip.mp4" type="video/mp4" medium="video"/>
            <ex:duration>1</ex:duration>
            <duration>1081</duration>
            <ex:keywords>stolen</ex:keywords>
            <keywords>kept</keywords>
            <embed><![CDATA[<iframe src="https://news.example/embed/abc123"></iframe>]]></embed>
          </item>
          <item>
            <guid>author-only</guid>
            <title>Byline</title>
            <link>https://news.example/byline</link>
            <ex:creator>Eve</ex:creator>
            <author>Grace</author>
            <ex:date>1999-01-01T00:00:00Z</ex:date>
            <dc:date>2020-01-03T00:00:00Z</dc:date>
            <description>The real article body</description>
            <ex:subtitle>Stolen subtitle</ex:subtitle>
            <itunes:subtitle>Episode subtitle</itunes:subtitle>
            <enclosure url="https://cdn.example/talk.mp3" length="12" type="audio/mpeg"/>
          </item>
        </channel>
      </rss>
    XML

    story = feed.items.first
    byline = feed.items.second
    expect(feed.title).to eq 'Real channel'
    expect(feed.site_url).to eq 'https://news.example'
    expect(feed.icon_hints).to eq [
      { 'kind' => 'rss_image', 'url' => 'https://cdn.example/rss.png' },
      { 'kind' => 'itunes_image', 'url' => 'https://cdn.example/cover.jpg' },
    ]
    expect(story.key).to eq 'real-guid'
    expect(story.title).to eq 'Real story'
    expect(story.canonical_url).to eq 'https://news.example/watch?id=abc123'
    expect(story.byline).to eq 'Ada'
    expect(story.body).to eq 'Encoded body'
    expect(story.published_at).to eq Time.zone.parse('Thu, 02 Jan 2020 03:04:05 GMT')
    expect(story.keywords).to eq ['kept']
    expect(story.media.map { |row| [row['kind'], row['url']] }).to eq [
      ['video', 'https://cdn.example/clip.mp4'],
      ['embed', 'https://news.example/embed/abc123'],
    ]
    expect(story.media.find { |row| row['kind'] == 'embed' }['duration']).to eq 1081
    expect(byline.byline).to eq 'Grace'
    expect(byline.body).to eq 'The real article body'
    expect(byline.published_at).to eq Time.zone.parse('2020-01-03T00:00:00Z')
    expect(byline.media.map { |row| row['url'] }).to eq ['https://cdn.example/talk.mp3']
  end

  it 'reads a prefixed RSS 1.0 document without taking foreign fields or a leading self link' do
    feed = described_class.parse!(<<~XML)
      <?xml version="1.0"?>
      <r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:s="http://purl.org/rss/1.0/"
             xmlns:d="http://purl.org/dc/elements/1.1/"
             xmlns:c="http://purl.org/rss/1.0/modules/content/"
             xmlns:a="http://www.w3.org/2005/Atom"
             xmlns:x="https://foreign.example/ns">
        <s:channel r:about="https://news.example/">
          <a:link rel="self" href="https://feeds.example/index.rdf"/>
          <x:title>Foreign channel</x:title>
          <s:title>Prefixed RDF</s:title>
          <x:link>https://evil.example/</x:link>
          <s:link>https://news.example/</s:link>
          <s:items><r:Seq>
            <r:li r:resource="https://news.example/second"/>
            <r:li r:resource="https://news.example/first"/>
          </r:Seq></s:items>
          <s:image r:resource="https://cdn.example/logo.png"/>
        </s:channel>
        <s:image r:about="https://cdn.example/logo.png"><s:url>https://cdn.example/logo.png</s:url></s:image>
        <s:item r:about="https://news.example/first">
          <x:guid>foreign-guid</x:guid>
          <x:title>No</x:title>
          <s:title>First</s:title>
          <s:link>https://news.example/first</s:link>
          <d:creator>Ada</d:creator>
          <d:date>2026-10-26T13:33:00+09:00</d:date>
          <c:encoded><![CDATA[<p>Encoded body</p>]]></c:encoded>
        </s:item>
        <s:item r:about="https://news.example/second">
          <s:title>Second</s:title>
          <s:link>https://news.example/second</s:link>
        </s:item>
      </r:RDF>
    XML

    expect(feed.title).to eq 'Prefixed RDF'
    expect(feed.site_url).to eq 'https://news.example'
    expect(feed.items.map(&:title)).to eq %w(Second First)
    expect(feed.items.map(&:key)).to eq ['https://news.example/second', 'https://news.example/first']
    expect(feed.items.second.byline).to eq 'Ada'
    expect(feed.items.second.body).to eq 'Encoded body'
    expect(feed.items.second.published_at).to eq Time.zone.parse('2026-10-26T13:33:00+09:00')
    expect(feed.icon_hints).to eq [{ 'kind' => 'rss_image', 'url' => 'https://cdn.example/logo.png' }]
  end

  describe 'Atom links (RFC 4287)' do
    # rel omitted, and rel="", mean alternate. self and enclosure are never
    # the page URL. A single rel value is one relation, not a token list.
    def atom_feed(feed_links:, entry_links:, content: '<content type="html">Kept body</content>')
      <<~XML
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom</title>
          #{feed_links}
          <entry>
            <id>urn:keep-id</id>
            <title>Entry</title>
            #{entry_links}
            #{content}
            <updated>2020-01-02T03:04:05Z</updated>
          </entry>
        </feed>
      XML
    end

    it 'uses an explicit alternate or an omitted rel, in either order, and ignores self and enclosure' do
      pages = [
        '<link rel="self" href="https://feeds.example/atom.xml"/><link rel="alternate" type="text/html" href="https://news.example/"/>',
        '<link rel="alternate" href="https://news.example/"/><link rel="self" href="https://feeds.example/atom.xml"/>',
        '<link rel="self" href="https://feeds.example/atom.xml"/><link href="https://news.example/"/>',
        '<link rel="" href="https://news.example/"/><link rel="enclosure" href="https://cdn.example/feed.mp3" type="audio/mpeg"/>',
        '<link rel="Alternate" type="text/html" href="https://news.example/"/>',
      ]
      pages.each do |feed_links|
        feed = described_class.parse!(atom_feed(feed_links: feed_links, entry_links: '<link href="https://news.example/entry"/>'))
        expect(feed.site_url).to eq 'https://news.example'
      end

      entries = [
        '<link rel="self" href="https://feeds.example/e"/><link rel="enclosure" href="https://cdn.example/note.mp3" type="audio/mpeg"/><link rel="alternate" type="text/html" href="https://news.example/entry"/>',
        '<link rel="alternate" href="https://news.example/entry"/><link rel="self" href="https://feeds.example/e"/>',
        '<link rel="enclosure" href="https://cdn.example/note.mp3" type="audio/mpeg"/><link href="https://news.example/entry"/>',
      ]
      entries.each do |entry_links|
        feed = described_class.parse!(atom_feed(feed_links: '<link href="https://news.example/"/>', entry_links: entry_links))
        expect(feed.items.first.canonical_url).to eq 'https://news.example/entry'
        expect(feed.items.first.key).to eq 'urn:keep-id'
      end
    end

    it 'does not invent a page URL from self, enclosure, or a non-page alternate, and keeps the id' do
      feed = described_class.parse!(atom_feed(
                                      feed_links: '<link rel="self" href="https://feeds.example/only-self.xml"/><link rel="enclosure" href="https://cdn.example/feed.mp3" type="audio/mpeg"/>',
                                      entry_links: <<~XML
                                        <link rel="self" href="https://feeds.example/only-self.xml#e"/>
                                        <link rel="enclosure" href="https://cdn.example/note.mp3" type="audio/mpeg" length="4"/>
                                        <link rel="alternate" type="application/atom+xml" href="https://feeds.example/entry.xml"/>
                                        <link rel="alternate related" href="https://news.example/not-a-single-relation"/>
                                      XML
                                    ))

      expect(feed.site_url).to be_nil
      expect(feed.items.first.key).to eq 'urn:keep-id'
      expect(feed.items.first.canonical_url).to be_nil
      expect(feed.items.first.body).to eq 'Kept body'
      expect(feed.items.first.media.map { |row| row['url'] }).to eq ['https://cdn.example/note.mp3']
      expect(feed.items.first.activitypub_sample_url).to be_nil
    end

    it 'keeps a typed ActivityPub link off the page URL even when it is the first alternate' do
      feed = described_class.parse!(<<~XML)
        <a:feed xmlns:a="http://www.w3.org/2005/Atom">
          <a:title>Prefixed Atom</a:title>
          <a:link rel="self" href="https://feeds.example/atom.xml"/>
          <a:link href="https://news.example/"/>
          <a:entry>
            <a:id>urn:prefixed</a:id>
            <z:title xmlns:z="https://foreign.example/ns">Other</z:title>
            <a:title>Entry</a:title>
            <a:link rel="alternate" type="application/activity+json" href="https://social.example/users/alice/statuses/1"/>
            <a:link rel="enclosure" href="https://cdn.example/voice.ogg" type="audio/ogg"/>
            <a:link rel="alternate" type="text/html" href="https://news.example/entry"/>
            <a:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>XHTML body</p><img src="https://cdn.example/x.png" alt="Pic"/></div></a:content>
            <a:updated>2020-01-02T03:04:05Z</a:updated>
          </a:entry>
        </a:feed>
      XML

      item = feed.items.first
      expect(feed.title).to eq 'Prefixed Atom'
      expect(feed.site_url).to eq 'https://news.example'
      expect(item.title).to eq 'Entry'
      expect(item.key).to eq 'urn:prefixed'
      expect(item.canonical_url).to eq 'https://news.example/entry'
      expect(item.activitypub_explicit).to be true
      expect(item.activitypub_url).to eq 'https://social.example/users/alice/statuses/1'
      expect(item.activitypub_sample_url).to be_nil
      expect(item.body).to eq 'XHTML body'
      expect(item.media.map { |row| [row['kind'], row['url']] }).to eq [
        ['audio', 'https://cdn.example/voice.ogg'],
        ['image', 'https://cdn.example/x.png'],
      ]
    end

    it 'prefers an explicit alternate over an earlier omitted rel, and skips a rejected href' do
      rejected_first = described_class.parse!(atom_feed(
                                                 feed_links: '<link href="https://user:secret@news.example/wrong"/><link rel="alternate" href="https://news.example/right"/>',
                                                 entry_links: '<link href="https://user:secret@news.example/wrong"/><link rel="alternate" href="https://news.example/right"/>'
                                               ))
      expect(rejected_first.site_url).to eq 'https://news.example/right'
      expect(rejected_first.items.first.canonical_url).to eq 'https://news.example/right'

      explicit_wins = described_class.parse!(atom_feed(
                                                feed_links: '<link href="https://news.example/omitted"/><link rel="alternate" href="https://news.example/explicit"/>',
                                                entry_links: '<link href="https://news.example/omitted"/><link rel="alternate" href="https://news.example/explicit"/>'
                                              ))
      expect(explicit_wins.site_url).to eq 'https://news.example/explicit'
      expect(explicit_wins.items.first.canonical_url).to eq 'https://news.example/explicit'

      swapped = described_class.parse!(atom_feed(
                                          feed_links: '<link rel="alternate" href="https://news.example/explicit"/><link href="https://news.example/omitted"/>',
                                          entry_links: '<link rel="alternate" href="https://news.example/explicit"/><link href="https://news.example/omitted"/>'
                                        ))
      expect(swapped.site_url).to eq 'https://news.example/explicit'
      expect(swapped.items.first.canonical_url).to eq 'https://news.example/explicit'

      fallback = described_class.parse!(atom_feed(
                                           feed_links: '<link rel="alternate" href="https://user:secret@news.example/bad"/><link href="https://news.example/omitted"/>',
                                           entry_links: '<link rel="alternate" href="http://127.0.0.1/secret"/><link href="https://news.example/omitted"/>'
                                         ))
      expect(fallback.site_url).to eq 'https://news.example/omitted'
      expect(fallback.items.first.canonical_url).to eq 'https://news.example/omitted'
    end

    it 'resolves entry media against the accepted page link, not a rejected leading link' do
      html = '<content type="html">&lt;img src="photo.png" alt="Relative"&gt;</content>'
      preferred = '<link href="https://user:secret@cdn.example/wrong"/><link rel="alternate" href="https://news.example/posts/1"/>'
      fallback_links = '<link rel="alternate" href="https://user:secret@cdn.example/wrong"/><link href="https://news.example/posts/1"/>'
      site = '<link rel="alternate" href="https://news.example/"/>'

      feed = described_class.parse!(atom_feed(feed_links: site, entry_links: preferred, content: html))
      expect(feed.items.first.canonical_url).to eq 'https://news.example/posts/1'
      expect(feed.items.first.media.map { |row| row['url'] }).to eq ['https://news.example/posts/photo.png']

      fallback = described_class.parse!(atom_feed(feed_links: site, entry_links: fallback_links, content: html))
      expect(fallback.items.first.canonical_url).to eq 'https://news.example/posts/1'
      expect(fallback.items.first.media.map { |row| row['url'] }).to eq ['https://news.example/posts/photo.png']
    end

    it 'keeps a later valid ActivityPub link when earlier typed links are rejected' do
      entry_links = <<~XML.squish
        <link rel="alternate" type="application/activity+json" href="http://127.0.0.1/object"/>
        <link rel="alternate" type="application/activity+json" href="https://user:secret@social.example/object"/>
        <link rel="alternate" type="application/activity+json" href="/relative-object"/>
        <link rel="alternate" type="text/html" href="https://news.example/entry"/>
        <link rel="alternate" type="application/activity+json" href="https://social.example/object"/>
      XML
      feed = described_class.parse!(atom_feed(
                                      feed_links: '<link rel="alternate" href="https://news.example/"/>',
                                      entry_links: entry_links
                                    ))

      item = feed.items.first
      expect(item.canonical_url).to eq 'https://news.example/entry'
      expect(item.activitypub_explicit).to be true
      expect(item.activitypub_url).to eq 'https://social.example/object'
      expect(item.activitypub_sample_url).to be_nil
    end
  end

  it 'does not treat a non-Atom feed element as an Atom feed' do
    foreign = <<~XML
      <foreign:feed xmlns:foreign="https://foreign.example/ns">
        <foreign:title>Not Atom</foreign:title>
        <foreign:link href="https://news.example/stolen"/>
      </foreign:feed>
    XML
    bare = '<feed><title>Bare</title><link href="https://news.example/"/></feed>'

    [foreign, bare].each do |xml|
      expect { described_class.parse!(xml) }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }
    end
  end
end

RSpec.describe ExternalBridge::RSS::Ingest do
  let(:feed_key) { 'https://feeds.example/namespace.xml' }
  let(:response) do
    ExternalBridge::RSS::HttpClient
    ExternalBridge::RSS::Response.new(code: 200)
  end

  def feed_xml(channel_link:, title: 'Namespace News')
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>
          <atom:link rel="self" href="#{feed_key}"/>
          #{channel_link}
          <title>#{title}</title>
          <item>
            <guid>story-1</guid>
            <title>Story</title>
            <atom:link rel="self" href="#{feed_key}#item"/>
            <link>https://news.example/story</link>
            <description>Body</description>
          </item>
        </channel>
      </rss>
    XML
  end

  def parsed(channel_link:, title: 'Namespace News')
    ExternalBridge::RSS::Parser.parse!(feed_xml(channel_link: channel_link, title: title))
  end

  it 'stores site_url and profile_url, keeps them when a later document has no page link, and preserves ids' do
    user = Fabricate(:user)
    enable_external_bridge_rss!(user)
    ingest = described_class.new

    source, resources = ingest.write_public!(parsed(channel_link: '<link>https://news.example/</link>'), feed_key, response)
    actor = ExternalActor.find_by!(protocol: 'rss', native_id: feed_key)
    resource = resources.first
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    _status, marker = ExternalBridge::ProjectionWriter.new.create!(
      user: user,
      subscription: subscription,
      resource: resource,
      text: 'Body'
    )

    expect(source.site_url).to eq 'https://news.example'
    expect(actor.profile_url).to eq 'https://news.example'
    expect(resource.canonical_url).to eq 'https://news.example/story'
    expect(resource.canonical_key).to eq "feed:#{feed_key}\nitem:story-1"

    ids = {
      source: source.id,
      actor: actor.id,
      resource: resource.id,
      marker: marker.id,
      status: marker.status_id,
      source_key: source.canonical_key,
      resource_key: resource.canonical_key,
    }

    ingest.apply_public!(source, parsed(channel_link: '<link>https://news.example/</link>', title: 'Still news'), response)
    ingest.apply_public!(source, parsed(channel_link: '', title: 'Self only'), response)

    expect(ExternalSource.where(canonical_key: feed_key).count).to eq 1
    expect(source.reload.id).to eq ids[:source]
    expect(source.canonical_key).to eq ids[:source_key]
    expect(source.title).to eq 'Self only'
    expect(source.site_url).to eq 'https://news.example'
    expect(actor.reload.id).to eq ids[:actor]
    expect(actor.profile_url).to eq 'https://news.example'
    expect(actor.display_name).to eq 'Self only'
    expect(resource.reload.id).to eq ids[:resource]
    expect(resource.canonical_key).to eq ids[:resource_key]
    expect(resource.canonical_url).to eq 'https://news.example/story'
    expect(marker.reload.id).to eq ids[:marker]
    expect(marker.status_id).to eq ids[:status]
    expect(marker.external_resource_id).to eq ids[:resource]
    expect(marker.external_source_id).to eq ids[:source]
    expect(source.external_resources.count).to eq 1
  end
end
