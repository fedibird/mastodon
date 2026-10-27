# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::PlayerResolver do
  def item_xml(extra)
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
        <title>Example</title>
        <link>https://watch.example.com</link>
        <item>
          <title>Example video</title>
          <link>https://watch.example.com/watch?id=abc123</link>
          #{extra}
        </item>
      </channel></rss>
    XML
  end

  def media_for(extra)
    ExternalBridge::RSS::Parser.parse!(item_xml(extra)).items.first
  end

  def kinds(extra)
    media_for(extra).media.map { |row| row['kind'] }
  end

  def decision(article, player)
    ExternalBridge::RSS::PlayerResolver.choose(
      article,
      [{ priority: 1, at: 0, origin: 'rss_embed', urls: [player] }]
    )
  end

  it 'reads a CDATA iframe src and keeps the larger poster as an image' do
    item = media_for(<<~XML)
      <duration>1081</duration>
      <thumb>https://images.example/assets/original.mp4/plain/ex:1/rs:fit:180:135?hash=token&amp;validto=111</thumb>
      <thumb_large>https://images.example/assets/original.mp4/plain/ex:1/rs:fit:320:240?hash=token&amp;validto=111</thumb_large>
      <embed><![CDATA[<iframe src="https://player.example.com/embed/abc123" width="560" height="340" allowfullscreen></iframe>]]></embed>
      <keywords><![CDATA[topic one,topic two]]></keywords>
    XML

    embed = item.media.find { |row| row['kind'] == 'embed' }
    poster = item.media.find { |row| row['role'] == 'poster' }
    expect(embed['url']).to eq 'https://player.example.com/embed/abc123'
    expect(embed['origin']).to eq 'rss_embed'
    expect(embed['duration']).to eq 1081
    expect(embed['poster_url']).to eq poster['url']
    expect(poster['url']).to include('rs:fit:320:240')
    expect(poster['url']).not_to include('hash=')
    expect(poster['fallbacks'].first).to include('rs:fit:180:135')
    expect(poster['fetch_url']).to include('hash=token')
    expect(item.keywords).to eq ['topic one', 'topic two']
    expect(item.media.map { |row| row['kind'] }).not_to include('video')
  end

  it 'reads an iframe element when the embed text is not wrapped in CDATA' do
    item = media_for('<embed><iframe src="https://player.example.com/embed/abc123" onload="alert(1)"></iframe></embed>')

    expect(item.media.map { |row| row['url'] }).to eq ['https://player.example.com/embed/abc123']
    expect(item.media.first.keys).not_to include('html')
  end

  it 'prefers media:player over a body iframe and does not keep the file as an embed' do
    item = media_for(<<~XML)
      <media:group>
        <media:content url="https://cdn.example/clip.mp4" type="video/mp4"/>
        <media:player url="https://player.example.com/embed/abc123"/>
      </media:group>
      <description><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe><img src="https://cdn.example/still.png" alt="Still">]]></description>
    XML

    expect(item.media.map { |row| [row['kind'], row['origin']] }).to eq [
      ['video', 'media_rss'],
      ['embed', 'media_player'],
      ['image', 'html_img'],
    ]
  end

  it 'does not keep a poster when the player is rejected' do
    item = media_for(<<~XML)
      <thumb_large>https://images.example/plain/still.png</thumb_large>
      <embed><![CDATA[<iframe src="https://site-b.com/embed/abc123"></iframe>]]></embed>
    XML

    expect(item.media).to eq []
  end

  it 'keeps a viewkey item and a same-site player, and still rejects an unsafe query' do
    feed = ExternalBridge::RSS::Parser.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://watch.example.com</link>
        <item>
          <title>Example video</title>
          <link>https://watch.example.com/view_video.php?viewkey=abc123</link>
          <duration>1081</duration>
          <thumb_large>https://images.example/large.png</thumb_large>
          <thumbnail>https://images.example/small.png</thumbnail>
          <embed><![CDATA[<iframe src="https://www.example.com/embed/abc123"></iframe>]]></embed>
        </item>
      </channel></rss>
    XML
    viewkey = feed.items.first
    embed = viewkey.media.find { |row| row['kind'] == 'embed' }
    stored = ExternalBridge::RSS::MediaDigest.normalize(viewkey.media)

    expect(viewkey.key).to eq 'https://watch.example.com/view_video.php?viewkey=abc123'
    expect(viewkey.body).to eq ''
    expect(embed['url']).to eq 'https://www.example.com/embed/abc123'
    expect(embed['duration']).to eq 1081
    expect(stored.find { |row| row['role'] == 'poster' }['url']).to eq 'https://images.example/large.png'
    expect(stored.map { |row| row['kind'] }).to eq %w(image embed)
    expect(ExternalBridge::RSS::Parser.parse!(<<~XML).items.first.media).to eq []
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://watch.example.com</link>
        <item>
          <title>Example video</title>
          <link>https://watch.example.com/view_video.php?viewkey=abc123</link>
          <embed><![CDATA[<iframe src="https://www.example.com/embed/other999"></iframe>]]></embed>
        </item>
      </channel></rss>
    XML
    expect(ExternalBridge::RSS::Parser.parse!(<<~XML).items).to eq []
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://watch.example.com</link>
        <item>
          <title>Example video</title>
          <link>https://watch.example.com/view_video.php?viewkey=abc123&amp;utm_source=ad</link>
          <embed><![CDATA[<iframe src="https://www.example.com/embed/abc123"></iframe>]]></embed>
        </item>
      </channel></rss>
    XML
  end

  it 'projects a player when the item has a title and link and no body or guid' do
    feed = ExternalBridge::RSS::Parser.parse!(<<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title><link>https://watch.example.com</link>
        <item>
          <title>Example video</title>
          <link>https://watch.example.com/watch?id=abc123</link>
          <embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>
        </item>
      </channel></rss>
    XML

    item = feed.items.first
    expect(item.key).to eq 'https://watch.example.com/watch?id=abc123'
    expect(item.body).to eq ''
    expect(item.media.map { |row| row['kind'] }).to eq ['embed']
  end

  it 'rejects a player on another registrable domain even when the id matches' do
    expect(decision('https://site-a.com/watch?id=abc123', 'https://site-b.com/embed/abc123')).to be_nil
    expect(decision('https://site-a.net/watch?id=abc123', 'https://site-b.net/embed/abc123')).to be_nil
    expect(decision('https://a.co.jp/watch?id=abc123', 'https://b.co.jp/embed/abc123')).to be_nil
    chosen = decision('https://jp.example.com/watch?id=abc123', 'https://www.example.com/embed/abc123')

    expect(chosen&.url).to eq 'https://www.example.com/embed/abc123'
  end

  it 'rejects unsafe player URLs and does not turn a direct file into an embed' do
    item = media_for(<<~XML)
      <embed><![CDATA[
        <iframe src="javascript:alert(1)"></iframe>
        <iframe src="data:text/html,hi"></iframe>
        <iframe src="https://user:pass@player.example.com/embed/abc123"></iframe>
        <iframe src="/embed/abc123"></iframe>
        <iframe src="http://player.example.com/embed/abc123"></iframe>
        <iframe src="https://127.0.0.1/embed/abc123"></iframe>
        <iframe src="https://localhost/embed/abc123"></iframe>
        <iframe src="https://player.example.evil.test/embed/abc123"></iframe>
        <iframe src="https://player.example.com/embed/other999"></iframe>
        <iframe src="https://player.example.com/abc123.mp4"></iframe>
        <iframe src="https://watch.example.com/watch?id=abc123"></iframe>
        <script>alert(1)</script>
      ]]></embed>
    XML

    expect(item.media).to eq []
    expect(item.media.to_json).not_to include('javascript')
    expect(item.media.to_json).not_to include('other999')
  end

  it 'stops scanning iframes after the limit' do
    frames = (1..4).map { '<iframe src="https://evil.test/embed/abc123"></iframe>' }.join
    frames += '<iframe src="https://player.example.com/embed/abc123"></iframe>'
    item = media_for("<embed><![CDATA[#{frames}]]></embed>")

    expect(item.media).to eq []
  end

  it 'stores a bounded keyword list and a duration that is a non-negative number of seconds' do
    words = (1..20).map { |number| "word#{number}" }.join(',')
    item = media_for(<<~XML)
      <duration>0</duration>
      <keywords><![CDATA[topic one,topic one,<script>alert(1)</script>,#{words},this keyword is far too long to keep in the bounded list]]></keywords>
      <embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>
    XML

    expect(item.media.first['duration']).to eq 0
    expect(item.keywords.size).to eq ExternalBridge::RSS::Limits::MAX_KEYWORDS
    expect(item.keywords.join).not_to include('<')
    expect(item.keywords.count { |word| word == 'topic one' }).to eq 1
  end

  it 'drops durations outside the accepted range' do
    expect(kinds('<duration>-1</duration><embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>')).to eq ['embed']
    huge = ExternalBridge::RSS::Limits::MAX_MEDIA_DURATION + 1
    over = media_for("<duration>#{huge}</duration><embed><![CDATA[<iframe src=\"https://player.example.com/embed/abc123\"></iframe>]]></embed>")
    clock = media_for('<duration>18:01</duration><embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>')
    expect(over.media.first).not_to have_key('duration')
    expect(clock.media.first).not_to have_key('duration')
  end

  it 'keeps the media revision when only the poster signature changes' do
    first = media_for('<thumb_large>https://images.example/assets/original.mp4/plain/ex:1/rs:fit:320:240?hash=aaa&amp;validto=10</thumb_large><embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>')
    second = media_for('<thumb_large>https://images.example/assets/original.mp4/plain/ex:1/rs:fit:320:240?hash=bbb&amp;validto=99</thumb_large><embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>')
    left = ExternalBridge::RSS::MediaDigest.normalize(first.media)
    right = ExternalBridge::RSS::MediaDigest.normalize(second.media)

    expect(ExternalBridge::RSS::MediaDigest.hexdigest(left)).to eq ExternalBridge::RSS::MediaDigest.hexdigest(right)
    expect(left.find { |row| row['role'] == 'poster' }['fetch_url']).not_to eq right.find { |row| row['role'] == 'poster' }['fetch_url']
    expect(left.find { |row| row['role'] == 'poster' }['url']).to eq right.find { |row| row['role'] == 'poster' }['url']
  end

  it 'does not treat different non-signature queries as the same poster' do
    one = ExternalBridge::RSS::PosterURL.pair('https://images.example/plain/rs:fit:320:240?image=one&hash=aaa&validto=10')
    two = ExternalBridge::RSS::PosterURL.pair('https://images.example/plain/rs:fit:320:240?image=two&hash=aaa&validto=10')

    expect(one.logical).not_to eq two.logical
    expect(one.logical).to include('image=one')
    expect(one.fetch).to include('hash=aaa')
  end

  it 'reads an Atom player and an RDF embed without dropping the entry body' do
    atom = ExternalBridge::RSS::Parser.parse!(<<~XML)
      <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
        <title>A</title>
        <link href="https://watch.example.com/"/>
        <entry>
          <id>urn:1</id>
          <title>Entry</title>
          <link href="https://watch.example.com/watch?id=abc123"/>
          <media:player url="https://player.example.com/embed/abc123"/>
          <content type="html">&lt;p&gt;Real body&lt;/p&gt;</content>
        </entry>
      </feed>
    XML
    rdf = ExternalBridge::RSS::Parser.parse!(<<~XML)
      <?xml version="1.0"?>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
        <channel rdf:about="https://watch.example.com/"><title>RDF</title><link>https://watch.example.com/</link></channel>
        <item rdf:about="https://watch.example.com/watch?id=abc123">
          <title>One</title>
          <link>https://watch.example.com/watch?id=abc123</link>
          <description>Summary</description>
          <embed><![CDATA[<iframe src="https://player.example.com/embed/abc123"></iframe>]]></embed>
        </item>
      </rdf:RDF>
    XML

    expect(atom.items.first.body).to eq 'Real body'
    expect(atom.items.first.media.map { |row| row['kind'] }).to eq ['embed']
    expect(rdf.items.first.body).to eq 'Summary'
    expect(rdf.items.first.media.map { |row| row['kind'] }).to eq ['embed']
  end
end
