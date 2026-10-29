# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::MediaExtractor do
  def parse(xml)
    ExternalBridge::RSS::Parser.parse!(xml)
  end

  it 'reads several RSS 2.0 enclosures and keeps document order' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title>
        <link>https://example.com</link>
        <item>
          <guid>guid-1</guid>
          <title>Hello</title>
          <link>https://example.com/hello</link>
          <enclosure url="https://cdn.example/a.mp3" type="audio/mpeg" length="12"/>
          <enclosure url="https://cdn.example/b.mp4" type="video/mp4" length="99"/>
          <description>Article body</description>
        </item>
      </channel></rss>
    XML

    media = feed.items.first.media
    expect(feed.items.first.body).to eq 'Article body'
    expect(media.map { |row| row['kind'] }).to eq %w(audio video)
    expect(media.map { |row| row['url'] }).to eq ['https://cdn.example/a.mp3', 'https://cdn.example/b.mp4']
    expect(media.map { |row| row['position'] }).to eq [0, 1]
    expect(media.second['length_hint']).to eq 99
    expect(media.second['mime_hint']).to eq 'video/mp4'
  end

  it 'reads an RSS 1.0 content:encoded body and ignores the feed image' do
    xml = <<~XML
      <?xml version="1.0"?>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel rdf:about="https://news.example/">
          <title>RDF</title>
          <link>https://news.example/</link>
          <image rdf:resource="https://cdn.example/logo.png"/>
        </channel>
        <image rdf:about="https://cdn.example/logo.png"><url>https://cdn.example/logo.png</url></image>
        <item rdf:about="https://news.example/one">
          <title>One</title>
          <link>https://news.example/one</link>
          <content:encoded><![CDATA[<p>Body <img src="https://cdn.example/one.png" alt="One alt"></p>]]></content:encoded>
          <description>Summary only</description>
        </item>
      </rdf:RDF>
    XML

    feed = parse(xml)
    expect(feed.items.first.body).to eq 'Body'
    expect(feed.items.first.media.map { |row| row['url'] }).to eq ['https://cdn.example/one.png']
    expect(feed.items.first.media.first['description']).to eq 'One alt'
    expect(feed.icon_hints.first['url']).to eq 'https://cdn.example/logo.png'
    expect(feed.items.first.media.map { |row| row['url'] }).not_to include('https://cdn.example/logo.png')
  end

  it 'keeps Atom html content when media:content would otherwise collide' do
    feed = parse(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
        <title>A</title>
        <link href="https://example.com/"/>
        <entry>
          <id>urn:1</id>
          <title>Entry</title>
          <link href="https://example.com/e"/>
          <media:content url="https://cdn.example/clip.mp4" type="video/mp4" medium="video"/>
          <content type="html">&lt;p&gt;Real body &lt;img src="https://cdn.example/page.png" alt="Page"&gt;&lt;/p&gt;</content>
          <updated>2020-01-02T03:04:05Z</updated>
        </entry>
      </feed>
    XML

    item = feed.items.first
    expect(item.body).to eq 'Real body'
    expect(item.media.map { |row| [row['kind'], row['url']] }).to eq [
      ['video', 'https://cdn.example/clip.mp4'],
      ['image', 'https://cdn.example/page.png'],
    ]
  end

  it 'does not treat Atom type=text as HTML' do
    feed = parse(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>A</title>
        <link href="https://example.com/"/>
        <entry>
          <id>urn:text</id>
          <title>Text</title>
          <link rel="enclosure" href="https://cdn.example/note.mp3" type="audio/mpeg" length="4"/>
          <content type="text">Look at &lt;img src="https://cdn.example/secret.png"&gt;</content>
        </entry>
      </feed>
    XML

    expect(feed.items.first.media.map { |row| row['url'] }).to eq ['https://cdn.example/note.mp3']
  end

  it 'reads Atom xhtml and an enclosure link' do
    feed = parse(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>A</title>
        <link href="https://example.com/"/>
        <entry>
          <id>urn:xh</id>
          <title>X</title>
          <link href="https://example.com/x"/>
          <link rel="enclosure" href="https://cdn.example/voice.ogg" type="audio/ogg"/>
          <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><img src="https://cdn.example/x.png" alt="X"/></div></content>
        </entry>
      </feed>
    XML

    expect(feed.items.first.media.map { |row| row['kind'] }).to eq %w(audio image)
  end

  it 'resolves a relative image against xml:base and drops unsafe URLs' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title>
        <link>https://example.com</link>
        <item>
          <guid>rel</guid>
          <title>Rel</title>
          <link>https://example.com/posts/1</link>
          <description><![CDATA[
            <img src="photo.png" alt="Relative">
            <img src="javascript:alert(1)" alt="Script">
            <img src="data:image/png;base64,aaaa" alt="Data">
            <img src="https://user:pass@cdn.example/secret.png" alt="Userinfo">
            <img src="https://cdn.example/token.png?token=abcd" alt="Token">
            <img src="http://127.0.0.1/local.png" alt="Local">
            <img src="https://cdn.example/ok.png?w=800" alt="Sized">
          ]]></description>
        </item>
      </channel></rss>
    XML

    urls = feed.items.first.media.map { |row| row['url'] }
    expect(urls).to eq ['https://example.com/posts/photo.png', 'https://cdn.example/ok.png?w=800']
  end

  it 'uses xml:base before the item link' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel xml:base="https://cdn.example/posts/">
        <title>Example</title>
        <link>https://example.com</link>
        <item>
          <guid>base</guid>
          <title>Base</title>
          <link>https://example.com/ignored</link>
          <description><![CDATA[<img src="photo.png" alt="Base">]]></description>
        </item>
      </channel></rss>
    XML

    expect(feed.items.first.media.first['url']).to eq 'https://cdn.example/posts/photo.png'
  end

  it 'keeps the first image, a srcset fallback, picture, video, and audio in order' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://example.com</link>
        <item>
          <guid>html</guid><title>Html</title><link>https://example.com/html</link>
          <description><![CDATA[
            <figure><img src="https://cdn.example/a.png" srcset="https://cdn.example/a-small.png 400w, https://cdn.example/a.png 800w" alt=""><figcaption>Caption A</figcaption></figure>
            <picture><source srcset="https://cdn.example/b.webp 800w"><img src="https://cdn.example/b.png" alt="B"></picture>
            <video poster="https://cdn.example/poster.jpg"><source src="https://cdn.example/clip.webm" type="video/webm"><source src="https://cdn.example/clip.mp4" type="video/mp4"></video>
            <audio src="https://cdn.example/talk.mp3"></audio>
            <img src="https://cdn.example/poster.jpg" alt="Same poster">
            <iframe src="https://youtube.example/embed/1"></iframe>
          ]]></description>
        </item>
      </channel></rss>
    XML

    media = feed.items.first.media
    expect(media.map { |row| [row['kind'], row['url']] }).to eq [
      ['image', 'https://cdn.example/a.png'],
      ['image', 'https://cdn.example/b.webp'],
      ['video', 'https://cdn.example/clip.mp4'],
      ['audio', 'https://cdn.example/talk.mp3'],
    ]
    expect(media.find { |row| row['url'] == 'https://cdn.example/b.webp' }['description']).to eq 'B'
    expect(media.first['description']).to eq 'Caption A'
    expect(media.find { |row| row['kind'] == 'video' }['poster_url']).to eq 'https://cdn.example/poster.jpg'
  end

  it 'picks the largest srcset width even when a small webp is listed first' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://example.com</link>
        <item>
          <guid>sharp</guid><title>Sharp</title><link>https://example.com/sharp</link>
          <description><![CDATA[
            <img src="https://cdn.example/small.png" srcset="https://cdn.example/small.png 320w, https://cdn.example/large.png 1280w" alt="Large">
            <picture>
              <source type="image/webp" srcset="https://cdn.example/tiny.webp 320w, https://cdn.example/mid.webp 640w">
              <source srcset="https://cdn.example/small.jpg 320w, https://cdn.example/print.jpg 1600w">
              <img src="https://cdn.example/fallback.jpg" alt="Print">
            </picture>
          ]]></description>
        </item>
      </channel></rss>
    XML

    expect(feed.items.first.media.map { |row| row['url'] }).to eq [
      'https://cdn.example/large.png',
      'https://cdn.example/print.jpg',
    ]
    expect(feed.items.first.media.map { |row| row['description'] }).to eq %w(Large Print)
  end

  it 'treats a Media RSS thumbnail next to a video as a poster' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
        <title>Example</title><link>https://example.com</link>
        <item>
          <guid>mrss</guid><title>M</title><link>https://example.com/m</link>
          <media:group>
            <media:content url="https://cdn.example/movie.mp4" type="video/mp4" fileSize="20"/>
            <media:thumbnail url="https://cdn.example/thumb.jpg"/>
          </media:group>
          <media:content url="https://cdn.example/still.jpg" medium="image"/>
          <description>Text</description>
        </item>
      </channel></rss>
    XML

    media = feed.items.first.media
    expect(media.map { |row| [row['kind'], row['url']] }).to eq [
      ['video', 'https://cdn.example/movie.mp4'],
      ['image', 'https://cdn.example/still.jpg'],
    ]
    expect(media.first['poster_url']).to eq 'https://cdn.example/thumb.jpg'
  end

  it 'maps the playback gate fixture onto the device cases' do
    xml = Rails.root.join('spec/fixtures/external_bridge/playback_feed.xml').read
    feed = parse(xml)
    items = feed.items.index_by(&:key)

    expect(items.keys).to eq %w(
      playback-story
      playback-forbidden
      playback-unsupported-mime
      playback-no-range
    )

    story = items['playback-story']
    expect(story.canonical_url).to eq 'https://example.com/playback-story'
    expect(story.media.map { |row| [row['kind'], row['url'], row['description']] }).to eq [
      ['image', 'https://cdn.example/playback.png', 'Still frame'],
      ['video', 'https://cdn.example/playback.mp4', 'MP4 byte range'],
      ['video', 'https://cdn.example/playback.webm', 'WebM'],
      ['video', 'https://cdn.example/playback.m3u8', 'HLS'],
      ['audio', 'https://cdn.example/playback.mp3', 'MP3'],
    ]

    expect(items['playback-forbidden'].media.map { |row| [row['kind'], row['url'], row['description']] }).to eq [
      ['video', 'https://cdn.example/playback-forbidden.mp4', 'HTTP 403'],
    ]
    expect(items['playback-forbidden'].canonical_url).to eq 'https://example.com/playback-forbidden'

    expect(items['playback-unsupported-mime'].media.map { |row| [row['kind'], row['url'], row['description']] }).to eq [
      ['video', 'https://cdn.example/playback-unsupported.mp4', 'Unsupported MIME'],
    ]
    expect(items['playback-unsupported-mime'].canonical_url).to eq 'https://example.com/playback-unsupported-mime'

    expect(items['playback-no-range'].media.map { |row| [row['kind'], row['url'], row['description']] }).to eq [
      ['video', 'https://cdn.example/playback-no-range.mp4', 'Range ignored'],
    ]
    expect(items['playback-no-range'].canonical_url).to eq 'https://example.com/playback-no-range'
  end

  it 'caps the candidate list' do
    images = (1..20).map { |number| %(<img src="https://cdn.example/#{number}.png" alt="#{number}">) }.join
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>N</title><link>https://example.com</link>
        <item><guid>many</guid><title>Many</title><description><![CDATA[#{images}]]></description></item>
      </channel></rss>
    XML

    expect(feed.items.first.media.size).to eq ExternalBridge::RSS::Limits::MAX_MEDIA_CANDIDATES
    expect(feed.items.first.media.first['url']).to eq 'https://cdn.example/1.png'
  end

  it 'keeps ordered fallbacks without changing the media revision' do
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://example.com</link>
        <item>
          <guid>fallbacks</guid><title>Fallbacks</title><link>https://example.com/fallbacks</link>
          <description><![CDATA[
            <img src="https://cdn.example/a.png" srcset="https://cdn.example/a.png 1x, https://cdn.example/a-2x.png 2x" alt="Density">
            <picture>
              <source media="(min-width: 1000px)" srcset="https://cdn.example/wide.png 1000w">
              <source type="image/webp" srcset="https://cdn.example/tiny.webp 320w, https://cdn.example/same.webp 800w">
              <source type="image/jpeg" srcset="https://cdn.example/same.jpg 800w">
              <img src="https://cdn.example/same.jpg" alt="Print">
            </picture>
            <img src="javascript:alert(1)" srcset="http://127.0.0.1/secret.png 2000w, https://cdn.example/public.png 100w" alt="Safe">
            Broken &lt;&lt;&lt; markup stays in the article
          ]]></description>
        </item>
      </channel></rss>
    XML

    item = feed.items.first
    expect(item.body).to include('Broken')
    media = item.media
    expect(media.map { |row| row['url'] }).to eq [
      'https://cdn.example/a.png',
      'https://cdn.example/wide.png',
      'https://cdn.example/public.png',
    ]
    expect(media.first['fallbacks']).to eq ['https://cdn.example/a-2x.png']
    expect(media.second['fallbacks']).to eq [
      'https://cdn.example/same.webp',
      'https://cdn.example/same.jpg',
      'https://cdn.example/tiny.webp',
    ]
    expect(media.second['description']).to eq 'Print'
    expect(media.third['fallbacks']).to be_nil
    expect(media.third['url']).to eq 'https://cdn.example/public.png'
    stored = ExternalBridge::RSS::MediaDigest.normalize(media)
    expect(stored.second['fallbacks']).to eq media.second['fallbacks']
    expect(ExternalBridge::RSS::MediaDigest.hexdigest(stored)).to eq ExternalBridge::RSS::MediaDigest.hexdigest(media.map { |row| row.except('fallbacks') })
  end

  it 'still imports the article when the HTML extractor fails' do
    allow_any_instance_of(ExternalBridge::RSS::MediaHtml).to receive(:add_node).and_raise(StandardError)
    feed = parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://example.com</link>
        <item>
          <guid>broken</guid><title>Broken</title>
          <description><![CDATA[<img src="https://cdn.example/a.png" alt="A">Article text]]></description>
        </item>
      </channel></rss>
    XML

    expect(feed.items.first.body).to include('Article text')
    expect(feed.items.first.media).to eq []
  end

  it 'reads a Media RSS thumbnail body when the url attribute is omitted' do
    feed = thumbnail_feed([
      <<~XML,
        <media:thumbnail>
          https://cdn.example/cover.png?width=800
        </media:thumbnail>
      XML
      '<media:thumbnail><![CDATA[https://cdn.example/cdata.png]]></media:thumbnail>',
    ])

    expect(feed.items.map { |item| item.media.map { |row| row['url'] } }).to eq [
      ['https://cdn.example/cover.png?width=800'],
      ['https://cdn.example/cdata.png'],
    ]
    expect(feed.items.first.media.first['origin']).to eq 'media_thumbnail'
    expect(feed.items.first.media.first['kind']).to eq 'image'
    expect(feed.items.first.media.first['position']).to eq 0
  end

  it 'keeps a thumbnail url attribute ahead of a different body' do
    feed = thumbnail_feed([
      <<~XML,
        <media:thumbnail url="https://cdn.example/attr.jpg">
          https://cdn.example/body.jpg
        </media:thumbnail>
      XML
      '<media:thumbnail url="https://cdn.example/only.png?width=800"/>',
      '<media:thumbnail url="cover.png"/>',
      <<~XML,
        <media:group>
          <media:group>
            <media:thumbnail url="nested.png"/>
          </media:group>
        </media:group>
      XML
    ])

    expect(feed.items.map { |item| item.media.map { |row| row['url'] } }).to eq [
      ['https://cdn.example/attr.jpg'],
      ['https://cdn.example/only.png?width=800'],
      ['https://example.com/posts/cover.png'],
      ['https://example.com/posts/nested.png'],
    ]
  end

  it 'does not use the thumbnail body when the url attribute is present but unusable' do
    bodies = 'https://cdn.example/body.png'
    feed = thumbnail_feed([
      %(<media:thumbnail url="">#{bodies}</media:thumbnail>),
      %(<media:thumbnail url="   ">#{bodies}</media:thumbnail>),
      %(<media:thumbnail url="javascript:alert(1)">#{bodies}</media:thumbnail>),
      %(<media:thumbnail url="https://cdn.example/nope.png?token=secret">#{bodies}</media:thumbnail>),
      %(<media:thumbnail url="https://user:pass@cdn.example/secret.png">#{bodies}</media:thumbnail>),
      %(<media:thumbnail url="https://">#{bodies}</media:thumbnail>),
    ])

    expect(feed.items.map { |item| item.media }).to all(eq([]))
  end

  it 'rejects thumbnail text that is not one explicit http URL' do
    feed = thumbnail_feed([
      '<media:thumbnail></media:thumbnail>',
      '<media:thumbnail>   </media:thumbnail>',
      '<media:thumbnail>cover.png</media:thumbnail>',
      '<media:thumbnail>See https://cdn.example/prose.png today</media:thumbnail>',
      '<media:thumbnail>https://cdn.example/one.png https://cdn.example/two.png</media:thumbnail>',
      '<media:thumbnail>https://cdn.example/one.pnghttps://cdn.example/two.png</media:thumbnail>',
      '<media:thumbnail><a href="https://cdn.example/child.png">https://cdn.example/child.png</a></media:thumbnail>',
      '<media:thumbnail><img src="https://cdn.example/img-child.png"/></media:thumbnail>',
      '<media:thumbnail>&lt;img src="https://cdn.example/escaped.png"&gt;</media:thumbnail>',
      '<media:thumbnail><![CDATA[<a href="https://cdn.example/cdata.png">x</a>]]></media:thumbnail>',
      <<~XML,
        <media:group>
          <media:group>
            <media:thumbnail>cover.png</media:thumbnail>
          </media:group>
        </media:group>
      XML
    ])

    expect(feed.items.map { |item| item.media }).to all(eq([]))
  end

  it 'accepts any Media RSS prefix and ignores thumbnails in another namespace' do
    prefixed = thumbnail_feed(
      [<<~XML],
        <m:thumbnail>
          https://cdn.example/prefixed.png?width=800
        </m:thumbnail>
      XML
      xmlns: 'xmlns:m="http://search.yahoo.com/mrss/"'
    )
    default_ns = thumbnail_feed([<<~XML])
      <thumbnail xmlns="http://search.yahoo.com/mrss/">
        https://cdn.example/default-ns.png
      </thumbnail>
    XML
    rejected = thumbnail_feed([
      '<thumbnail url="https://cdn.example/direct-attr.png">https://cdn.example/direct-body.png</thumbnail>',
      '<other:thumbnail xmlns:other="https://other.example/ns" url="https://cdn.example/other-attr.png">https://cdn.example/other-body.png</other:thumbnail>',
      <<~XML,
        <media:group>
          <thumbnail url="https://cdn.example/level-attr.png">https://cdn.example/level-body.png</thumbnail>
        </media:group>
      XML
      <<~XML,
        <media:group>
          <media:group>
            <thumbnail url="https://cdn.example/deep-attr.png">https://cdn.example/deep-body.png</thumbnail>
            <other:thumbnail xmlns:other="https://other.example/ns">https://cdn.example/deep-other.png</other:thumbnail>
            <group>
              <media:thumbnail>https://cdn.example/inside-plain-group.png</media:thumbnail>
            </group>
            <media:thumbnail>
              https://cdn.example/deep-ok.png
            </media:thumbnail>
          </media:group>
        </media:group>
      XML
    ])

    expect(prefixed.items.first.media.map { |row| row['url'] }).to eq ['https://cdn.example/prefixed.png?width=800']
    expect(default_ns.items.first.media.map { |row| row['url'] }).to eq ['https://cdn.example/default-ns.png']
    expect(rejected.items[0].media).to eq []
    expect(rejected.items[1].media).to eq []
    expect(rejected.items[2].media).to eq []
    expect(rejected.items[3].media.map { |row| row['url'] }).to eq ['https://cdn.example/deep-ok.png']
  end

  it 'rejects thumbnail body URLs that fail the existing public URL rules' do
    long = "https://cdn.example/#{'a' * 2_100}.png"
    feed = thumbnail_feed([
      '<media:thumbnail>https://user:pass@cdn.example/secret.png</media:thumbnail>',
      '<media:thumbnail>https://cdn.example/token.png?token=abcd</media:thumbnail>',
      '<media:thumbnail>http://127.0.0.1/local.png</media:thumbnail>',
      '<media:thumbnail>http://localhost/local.png</media:thumbnail>',
      '<media:thumbnail>javascript:alert(1)</media:thumbnail>',
      '<media:thumbnail>data:image/png;base64,aaaa</media:thumbnail>',
      "<media:thumbnail>#{long}</media:thumbnail>",
    ])

    expect(feed.items.map { |item| item.media }).to all(eq([]))
  end

  it 'uses a body thumbnail as a video poster without a second attachment' do
    feed = thumbnail_feed([
      <<~XML,
        <media:content url="https://cdn.example/movie.mp4" type="video/mp4"/>
        <media:thumbnail>
          https://cdn.example/sibling-thumb.jpg
        </media:thumbnail>
        <description><![CDATA[<img src="https://cdn.example/sibling-thumb.jpg" alt="Same">]]></description>
      XML
      <<~XML,
        <media:content url="https://cdn.example/nested.mp4" type="video/mp4">
          <media:thumbnail>
            https://cdn.example/nested-thumb.jpg
          </media:thumbnail>
        </media:content>
        <description><![CDATA[<img src="https://cdn.example/nested-thumb.jpg" alt="Same">]]></description>
      XML
      <<~XML,
        <media:group>
          <media:group>
            <media:content url="https://cdn.example/deep.mp4" type="video/mp4"/>
            <media:thumbnail>
              https://cdn.example/deep-thumb.jpg
            </media:thumbnail>
          </media:group>
        </media:group>
      XML
      <<~XML,
        <media:group>
          <media:group>
            <media:content url="https://cdn.example/deep-nested.mp4" type="video/mp4">
              <media:thumbnail>
                https://cdn.example/deep-nested-thumb.jpg
              </media:thumbnail>
            </media:content>
          </media:group>
        </media:group>
      XML
    ])

    sibling, nested, deep, deep_nested = feed.items.map(&:media)
    expect(sibling.map { |row| [row['kind'], row['url'], row['position']] }).to eq [
      ['video', 'https://cdn.example/movie.mp4', 0],
    ]
    expect(sibling.first['poster_url']).to eq 'https://cdn.example/sibling-thumb.jpg'
    expect(nested.map { |row| [row['kind'], row['url']] }).to eq [
      ['video', 'https://cdn.example/nested.mp4'],
    ]
    expect(nested.first['poster_url']).to eq 'https://cdn.example/nested-thumb.jpg'
    expect(deep.first['poster_url']).to eq 'https://cdn.example/deep-thumb.jpg'
    expect(deep.map { |row| row['url'] }).to eq ['https://cdn.example/deep.mp4']
    expect(deep_nested.first['poster_url']).to eq 'https://cdn.example/deep-nested-thumb.jpg'
    expect(deep_nested.map { |row| row['url'] }).to eq ['https://cdn.example/deep-nested.mp4']
  end

  it 'keeps mixed media order when a body thumbnail is the poster' do
    feed = thumbnail_feed([<<~XML])
      <media:content url="https://cdn.example/one.png" medium="image"/>
      <media:thumbnail>
        https://cdn.example/poster.jpg
      </media:thumbnail>
      <media:content url="https://cdn.example/clip-a.mp4" type="video/mp4"/>
      <media:content url="https://cdn.example/two.png" medium="image"/>
      <enclosure url="https://cdn.example/talk.mp3" type="audio/mpeg"/>
      <description><![CDATA[<img src="https://cdn.example/poster.jpg" alt="Poster"><img src="https://cdn.example/one.png" alt="One">]]></description>
    XML

    media = feed.items.first.media
    expect(media.map { |row| [row['kind'], row['url'], row['position']] }).to eq [
      ['image', 'https://cdn.example/one.png', 0],
      ['video', 'https://cdn.example/clip-a.mp4', 1],
      ['image', 'https://cdn.example/two.png', 2],
      ['audio', 'https://cdn.example/talk.mp3', 3],
    ]
    expect(media[1]['poster_url']).to eq 'https://cdn.example/poster.jpg'
    expect(media.map { |row| row['url'] }).not_to include('https://cdn.example/poster.jpg')
  end

  it 'caps thumbnail body candidates at the existing limit' do
    fragments = (1..20).map { |number| %(<media:thumbnail>https://cdn.example/cap-#{number}.png</media:thumbnail>) }
    feed = thumbnail_feed([fragments.join])

    media = feed.items.first.media
    expect(media.size).to eq ExternalBridge::RSS::Limits::MAX_MEDIA_CANDIDATES
    expect(media.first['url']).to eq 'https://cdn.example/cap-1.png'
    expect(media.last['url']).to eq 'https://cdn.example/cap-12.png'
    expect(media.map { |row| row['position'] }).to eq (0...media.size).to_a
  end

  def thumbnail_feed(fragments, xmlns: 'xmlns:media="http://search.yahoo.com/mrss/"')
    items = fragments.each_with_index.map { |fragment, index| thumbnail_item(fragment, index) }.join
    parse(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0" #{xmlns}><channel>
        <title>Example</title>
        <link>https://example.com</link>
        #{items}
      </channel></rss>
    XML
  end

  def thumbnail_item(fragment, index)
    <<~XML
      <item>
        <guid>thumb-#{index}</guid>
        <title>Thumb #{index}</title>
        <link>https://example.com/posts/1</link>
        #{fragment}
      </item>
    XML
  end
end
