# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Parser do
  def record_html
    html = []
    allow(ExternalBridge::RSS::MediaHtml).to receive(:extract).and_wrap_original do |method, fragment, *args|
      html << fragment.to_s
      method.call(fragment, *args)
    end
    html
  end

  it 'extracts HTML and media for 40 of 1017 generated items' do
    html = record_html
    expect(ExternalBridge::RSS::MediaExtractor).not_to receive(:index!)

    feed = described_class.parse!(ExternalBridge::RSS::SyntheticFeed.html_items(1017))

    expect(html.size).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
    expect(feed.items.size).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
    expect(feed.items.first.key).to eq 'synthetic-0001'
    expect(feed.items.last.key).to eq 'synthetic-0040'
    kinds = feed.items.first.media.map { |row| row['kind'] }
    expect(kinds).to include('audio', 'image')
  end

  it 'leaves a large description and a nested media group after the window untouched' do
    html = record_html
    xml = ExternalBridge::RSS::SyntheticFeed.html_items(40)
    tail = <<~XML
      <item>
        <title>Late</title>
        <guid>synthetic-late</guid>
        <link>https://articles.example/notes/late</link>
        <description><![CDATA[<p>LATEMARKER #{'q' * 20_000}</p>]]></description>
        #{'<skip/>' * 200}
        <media:group xmlns:media="http://search.yahoo.com/mrss/">
          <media:group>
            <media:content url="https://media.example/audio/late.mp3" type="audio/mpeg"/>
          </media:group>
        </media:group>
      </item>
    XML
    xml = xml.sub('</channel>', "#{tail}</channel>")
    expect(ExternalBridge::RSS::MediaGroup).not_to receive(:collect)

    feed = described_class.parse!(xml)

    expect(feed.items.size).to eq 40
    expect(feed.items.map(&:key)).not_to include('synthetic-late')
    expect(html.join).not_to include('LATEMARKER')
    expect(html.size).to eq 40
  end

  it 'does not fill the window when an earlier node has no identity' do
    body = +ExternalBridge::RSS::SyntheticFeed.channel_open
    body << '<item><title>Hole</title><description>no identity</description></item>'
    40.times { |index| body << ExternalBridge::RSS::SyntheticFeed.compact_item(index) }
    body << ExternalBridge::RSS::SyntheticFeed.channel_close

    feed = described_class.parse!(body)

    expect(feed.items.size).to eq 39
    expect(feed.items.map(&:title)).not_to include('Hole')
    expect(feed.items.map(&:key)).to eq (1..39).map { |number| format('synthetic-%04d', number) }
  end

  it 'keeps duplicate guids in the window and does not pull in the next item' do
    feed = described_class.parse!(ExternalBridge::RSS::SyntheticFeed.duplicate_guids)

    expect(feed.items.size).to eq 40
    expect(feed.items.map(&:title).first(2)).to eq ['First shared', 'Second shared']
    expect(feed.items.map(&:key).count('synthetic-shared')).to eq 2
    expect(feed.items.last.key).to eq 'synthetic-0041'
    expect(feed.items.map(&:key)).not_to include('synthetic-0042')
  end

  it 'follows rdf:Seq order for the 40 items it extracts' do
    indexed = nil
    allow(ExternalBridge::RSS::MediaExtractor).to receive(:index_items!).and_wrap_original do |method, nodes|
      indexed = nodes.size
      method.call(nodes)
    end

    feed = described_class.parse!(ExternalBridge::RSS::SyntheticFeed.rdf_feed(50))

    expect(indexed).to eq 40
    expect(feed.items.map(&:title)).to eq (11..50).map { |number| format('Synthetic note %04d', number) }.reverse
    expect(feed.items.first.canonical_url).to eq 'https://articles.example/notes/0050'
    expect(feed.items.last.canonical_url).to eq 'https://articles.example/notes/0011'
  end
end
