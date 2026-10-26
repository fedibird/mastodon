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
end
