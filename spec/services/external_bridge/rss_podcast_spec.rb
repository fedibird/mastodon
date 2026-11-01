# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ExternalBridge RSS podcast compatibility' do
  let(:feed_url) { 'https://feeds.megaphone.fm/TBS2679398439' }
  let(:audio_url) { 'https://pdst.fm/e/pscrb.fm/rss/p/traffic.megaphone.fm/TBS6010297062.mp3?updated=1778400748' }
  let(:advertising) { 'Learn more about your ad choices. Visit podcastchoices.com/adchoices' }
  let(:episode_text) { '2026年10月25日の「にち10ポッドキャスト」は、「サイドラインギリギリの醤油トーク」を配信します。' }

  def podcast_xml(description:, encoded:, subtitle:, enclosure_url: audio_url)
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>安住紳一郎の日曜天国</title>
          <link>https://www.tbsradio.jp/nichiten/</link>
          <image><url>https://cdn.example/normal.jpg</url></image>
          <itunes:image href="https://megaphone.imgix.net/podcast/cover.jpg?ixlib=rails-4.3.1&amp;max-w=3000&amp;max-h=3000&amp;fit=crop&amp;auto=format,compress"/>
          <item>
            <title>2026.10.25「サイドラインギリギリの醤油トーク」</title>
            <guid isPermaLink="false">5d011ee0-d048-11f1-8fd9-1f8bda7517c6</guid>
            <description>#{description}</description>
            <content:encoded><![CDATA[#{encoded}]]></content:encoded>
            <itunes:subtitle>#{subtitle}</itunes:subtitle>
            <itunes:duration>1674</itunes:duration>
            <pubDate>Sun, 25 Oct 2026 07:47:00 -0000</pubDate>
            <enclosure url="#{enclosure_url.gsub('&', '&amp;')}" length="0" type="audio/mpeg"/>
          </item>
        </channel>
      </rss>
    XML
  end

  it 'imports a linkless podcast episode with its subtitle and remote audio URL' do
    user = Fabricate(:user)
    enable_external_bridge_rss!(user)
    xml = podcast_xml(description: advertising, encoded: '<p> </p><p>Learn more about your ad choices. Visit podcastchoices.com/adchoices</p>', subtitle: episode_text)
    stub_request(:get, feed_url).to_return(status: 200, body: xml, headers: { 'Content-Type' => 'application/rss+xml' })

    subscription = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    resource = subscription.external_source.external_resources.sole
    projection = ExternalStatusProjection.find_by!(user: user, external_resource: resource)
    status = Status.find(projection.status_id)

    expect(resource.canonical_key).to include('5d011ee0-d048-11f1-8fd9-1f8bda7517c6')
    expect(resource.canonical_url).to be_nil
    expect(resource.body).to eq episode_text
    expect(status.text).to include(episode_text)
    expect(status.text).not_to include('Learn more about your ad choices')
    expect(resource.media_candidates.map { |row| [row['kind'], row['url'], row['length_hint']] }).to eq [
      ['audio', audio_url, 0],
    ]
    expect(ExternalBridge::RSS::Media::RemotePayload.for(projection).map { |row| [row[:type], row[:url], row[:delivery]] }).to eq [
      ['audio', audio_url, 'remote'],
    ]
    expect(subscription.external_source.icon_hints.map { |hint| hint['kind'] }).to eq %w(rss_image itunes_image)
  end

  it 'preserves a substantive RSS description instead of replacing it with the subtitle' do
    xml = podcast_xml(description: 'The real article body', encoded: "<p>#{advertising}</p>", subtitle: episode_text)
    item = ExternalBridge::RSS::Parser.parse!(xml).items.first

    expect(item.body).to eq 'The real article body'
    expect(item.media.first['url']).to eq audio_url
  end

  it 'keeps a substantive content:encoded before other podcast text' do
    xml = podcast_xml(description: 'Short RSS summary', encoded: '<p>Longer substantive article content</p>', subtitle: episode_text)
    item = ExternalBridge::RSS::Parser.parse!(xml).items.first

    expect(item.body).to eq 'Longer substantive article content'
  end

  it 'does not use iTunes subtitle in an ordinary text feed without an audio enclosure' do
    # With no audio enclosure, retain the ordinary RSS fallback order:
    # an empty content:encoded falls back to description, never iTunes subtitle.
    xml = podcast_xml(description: advertising, encoded: '', subtitle: episode_text)
    xml = xml.sub(/<enclosure [^>]+\/>/, '')
    item = ExternalBridge::RSS::Parser.parse!(xml).items.first

    expect(item.body).to eq advertising
    expect(item.media).to be_empty
  end

  it 'accepts only bounded numeric updated parameters and no credential query aliases' do
    expect(ExternalBridge::RSS::MediaURL.normalize(audio_url)).to eq audio_url
    %w(updated=secret updated=123abc updated=1234567890123 token=123 API_KEY=123).each do |query|
      expect(ExternalBridge::RSS::MediaURL.normalize("https://cdn.example/talk.mp3?#{query}")).to be_nil
    end
  end

  it 'allows a podcast-sized feed while preserving the 8 MiB HTTP limit and 40-item parser cap' do
    expect(ExternalBridge::RSS::Limits::MAX_RESPONSE_BYTES).to eq 8.megabytes
    expect(ExternalBridge::RSS::Limits::MAX_ITEMS).to eq 40

    xml = podcast_xml(description: advertising, encoded: '<p> </p>', subtitle: episode_text)
    padded = xml.sub('</channel>', "<!-- #{'x' * 1_200_000} --></channel>")
    stub_request(:get, feed_url).to_return(status: 200, body: padded)
    response = ExternalBridge::RSS::HttpClient.get(feed_url)
    expect(response.body.bytesize).to be > 1.megabyte
    expect(ExternalBridge::RSS::Parser.parse!(response.body).items.size).to eq 1

    stub_request(:get, feed_url).to_return(status: 200, body: 'x' * (8.megabytes + 1))
    expect { ExternalBridge::RSS::HttpClient.get(feed_url) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end
end
