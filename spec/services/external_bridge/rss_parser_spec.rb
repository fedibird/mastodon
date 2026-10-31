# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Parser do
  def rdf(body)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        #{body}
      </rdf:RDF>
    XML
  end

  it 'reads an RSS 1.0 channel, sequence order, dc fields, and the feed image' do
    feed = described_class.parse!(rdf(<<~XML))
      <channel rdf:about="https://news.example/">
        <title>Example RDF</title>
        <link>https://news.example/</link>
        <items><rdf:Seq>
          <rdf:li rdf:resource="https://news.example/second" />
          <rdf:li rdf:resource="https://news.example/first" />
        </rdf:Seq></items>
        <image rdf:resource="https://cdn.example/logo.png" />
      </channel>
      <image rdf:about="https://cdn.example/logo.png"><url>https://cdn.example/logo.png</url></image>
      <item rdf:about="https://news.example/first">
        <title>First</title>
        <link>https://news.example/first</link>
        <dc:date>2026-10-26T13:33:00+09:00</dc:date>
      </item>
      <item rdf:about="https://news.example/second"><title>Second</title><link>https://news.example/second</link></item>
      <item rdf:about="https://news.example/extra"><title>Extra</title><description>After the sequence</description></item>
    XML

    expect(feed.protocol).to eq 'rss'
    expect(feed.title).to eq 'Example RDF'
    expect(feed.site_url).to eq 'https://news.example'
    expect(feed.items.map(&:title)).to eq ['Second', 'First', 'Extra']
    expect(feed.items.first.published_at).to be_nil
    expect(feed.items.second.published_at).to eq Time.zone.parse('2026-10-26T13:33:00+09:00')
    expect(feed.items.third.body).to eq 'After the sequence'
    expect(feed.items.third.key).to eq 'https://news.example/extra'
    expect(feed.icon_hints).to eq [{ 'kind' => 'rss_image', 'url' => 'https://cdn.example/logo.png' }]
  end

  it 'accepts items nested in the channel and an image URL carried only by rdf:resource' do
    feed = described_class.parse!(rdf(<<~XML))
      <channel>
        <title>Nested</title>
        <link>https://news.example/nested</link>
        <image rdf:resource="https://cdn.example/only.png" />
        <item>
          <title>Inside</title>
          <link>https://news.example/inside</link>
          <description>Body</description>
        </item>
      </channel>
    XML

    expect(feed.items.map(&:title)).to eq ['Inside']
    expect(feed.items.first.canonical_url).to eq 'https://news.example/inside'
    expect(feed.icon_hints.first['url']).to eq 'https://cdn.example/only.png'
  end

  it 'keeps the RSS 2.0 item fields and also accepts a dc:date' do
    feed = described_class.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example feed</title>
        <link>https://example.com</link>
        <image><url>https://cdn.example/rss.png</url></image>
        <item>
          <guid>guid-1</guid>
          <title>Hello</title>
          <link>https://example.com/hello</link>
          <description>Article body</description>
          <pubDate>Thu, 02 Jan 2020 03:04:05 GMT</pubDate>
          <author>Ada</author>
        </item>
        <item>
          <title>Dated</title>
          <link>https://example.com/dated</link>
          <dc:date xmlns:dc="http://purl.org/dc/elements/1.1/">2020-01-03T00:00:00Z</dc:date>
        </item>
      </channel></rss>
    XML

    expect(feed.items.map(&:key)).to eq ['guid-1', 'https://example.com/dated']
    expect(feed.items.first.byline).to eq 'Ada'
    expect(feed.items.first.body).to eq 'Article body'
    expect(feed.items.first.published_at).to eq Time.zone.parse('Thu, 02 Jan 2020 03:04:05 GMT')
    expect(feed.items.second.published_at).to eq Time.zone.parse('2020-01-03T00:00:00Z')
    expect(feed.icon_hints.first['url']).to eq 'https://cdn.example/rss.png'
  end

  it 'keeps a channel lastBuildDate off the item and rejects a date that is only a clock time' do
    feed = described_class.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example feed</title>
        <link>https://example.com</link>
        <lastBuildDate>Thu, 02 Jan 2020 08:00:00 GMT</lastBuildDate>
        <item>
          <guid>clock-only</guid>
          <title>Clock</title>
          <link>https://example.com/clock</link>
          <pubDate>10:00:00</pubDate>
        </item>
      </channel></rss>
    XML

    expect(feed.items.first.published_at).to be_nil
  end

  it 'falls back from an invalid pubDate to a valid dc:date and normalizes the offset' do
    feed = described_class.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>
        <title>Example feed</title>
        <link>https://example.com</link>
        <item>
          <guid>fallback</guid>
          <title>Fallback</title>
          <link>https://example.com/fallback</link>
          <pubDate>not-a-date</pubDate>
          <dc:date>2020-01-02T12:00:00+09:00</dc:date>
        </item>
        <item>
          <guid>numeric-zone</guid>
          <title>Zone</title>
          <link>https://example.com/zone</link>
          <pubDate>Thu, 02 Jan 2020 12:00:00 +0900</pubDate>
        </item>
      </channel></rss>
    XML

    expect(feed.items.first.published_at).to eq Time.utc(2020, 1, 2, 3, 0, 0)
    expect(feed.items.second.published_at).to eq Time.utc(2020, 1, 2, 3, 0, 0)
  end

  it 'does not fill in today when an Atom date is incomplete, and uses updated when published is unusable' do
    feed = described_class.parse!(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>A</title>
        <link href="https://example.com/"/>
        <entry>
          <id>urn:bad-published</id>
          <title>Bad</title>
          <link href="https://example.com/bad"/>
          <published>not-a-date</published>
          <updated>2020-01-02T03:04:05Z</updated>
        </entry>
        <entry>
          <id>urn:date-only</id>
          <title>Date</title>
          <link href="https://example.com/date"/>
          <published>2020-01-02</published>
          <updated>10:00</updated>
        </entry>
        <entry>
          <id>urn:published-wins</id>
          <title>Wins</title>
          <link href="https://example.com/wins"/>
          <published>2020-06-01T00:00:00Z</published>
          <updated>2021-01-01T00:00:00Z</updated>
        </entry>
      </feed>
    XML

    expect(feed.items.map(&:published_at)).to eq [
      Time.utc(2020, 1, 2, 3, 4, 5),
      nil,
      Time.utc(2020, 6, 1, 0, 0, 0),
    ]
  end

  it 'still reads an Atom feed' do
    feed = described_class.parse!(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>A</title>
        <link href="https://example.com/"/>
        <entry><id>urn:1</id><title>Entry</title><link href="https://example.com/e"/><updated>2020-01-02T03:04:05Z</updated></entry>
      </feed>
    XML

    expect(feed.protocol).to eq 'atom'
    expect(feed.items.map(&:key)).to eq ['urn:1']
    expect(feed.items.first.canonical_url).to eq 'https://example.com/e'
  end

  it 'caps the number of RSS 1.0 items' do
    items = (1..45).map { |number| %(<item rdf:about="https://news.example/#{number}"><title>#{number}</title></item>) }.join
    feed = described_class.parse!(rdf(%(<channel><title>Many</title><link>https://news.example/</link></channel>#{items})))

    expect(feed.items.size).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
    expect(feed.items.first.title).to eq '1'
  end

  it 'does not resolve an external entity in an RSS 1.0 title' do
    xml = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rdf:RDF [ <!ENTITY xxe SYSTEM "http://127.0.0.1/xxe-secret"> ]>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
        <channel rdf:about="https://news.example/"><title>&xxe;</title><link>https://news.example/</link></channel>
      </rdf:RDF>
    XML

    feed = described_class.parse!(xml)
    expect(feed.title.to_s).not_to include('SECRET')
  end

  it 'distinguishes unreadable XML from a document that is not a feed' do
    expect { described_class.parse!('not xml') }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
    expect { described_class.parse!('<rss>') }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
    expect { described_class.parse!('<html><body>No</body></html>') }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }
    expect { described_class.parse!(rdf('<channel/>').sub('<channel/>', '')) }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'malformed_feed' }
  end
end
