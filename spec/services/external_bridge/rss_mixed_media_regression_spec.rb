# frozen_string_literal: true

require 'rails_helper'

# Owner-only RSS/Atom/Media RSS articles can carry several images and several
# video or audio files. Images are saved locally up to the attachment cap.
# Video and audio files that are not saved stay remote, in their original
# relative order, under the image gallery. This does not allow a local post
# to attach more than one video, and it does not select more than one iframe.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'External RSS mixed media regression', type: :request do
  let(:png) { Rails.root.join('spec/fixtures/files/emojo.png').binread }
  let(:user) { Fabricate(:user) }
  let(:stranger) { Fabricate(:user) }
  let(:roommate) { share_account_user(user.account) }

  before { enable_external_bridge_rss!(user, stranger, roommate) }

  describe 'Media RSS and HTML candidates' do
    it 'keeps interleaved images, two remote videos, and audio, and does not gallery the poster' do
      item = parse_item(mixed_feed)

      expect(item.body).to eq 'Secret mixed article'
      expect(item.media.map { |row| [row['kind'], row['role'], row['url'], row['position']] }).to eq [
        ['image', 'attachment', image_url(1), 0],
        ['video', 'attachment', video_url('a'), 1],
        ['image', 'attachment', image_url(2), 2],
        ['video', 'attachment', video_url('b'), 3],
        ['image', 'attachment', image_url(3), 4],
        ['audio', 'attachment', audio_url, 5],
        ['image', 'attachment', poster_url, 6],
      ]
      expect(item.media.last['origin']).to eq 'html_img'
      expect(item.media.first['description']).to eq 'One'
      expect(item.media[1]['poster_url']).to eq poster_url
      expect(item.media[3]['poster_url']).to eq poster_url
      expect(item.media[1]['url']).not_to eq item.media[3]['url']
    end

    it 'keeps the same interleaved order for an Atom entry' do
      item = parse_item(<<~XML)
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <title>Mixed</title>
          <link href="https://example.com/"/>
          <entry>
            <id>urn:mixed</id>
            <title>Mixed story</title>
            <link href="https://example.com/mixed-story"/>
            <media:thumbnail url="#{poster_url}"/>
            <media:content url="#{image_url(1)}" medium="image" type="image/png"/>
            <media:content url="#{video_url('a')}" medium="video" type="video/mp4"/>
            <media:content url="#{image_url(2)}" medium="image" type="image/png"/>
            <media:content url="#{video_url('b')}" medium="video" type="video/mp4"/>
            <media:content url="#{image_url(3)}" medium="image" type="image/png"/>
            <link rel="enclosure" href="#{audio_url}" type="audio/mpeg" length="20"/>
            <content type="html">&lt;p&gt;Secret mixed article &lt;img src="#{poster_url}" alt="Poster duplicate"&gt;&lt;/p&gt;</content>
            <updated>2020-01-02T03:04:05Z</updated>
          </entry>
        </feed>
      XML

      expect(item.body).to eq 'Secret mixed article'
      expect(item.media.map { |row| [row['kind'], row['url']] }).to eq [
        ['image', image_url(1)],
        ['video', video_url('a')],
        ['image', image_url(2)],
        ['video', video_url('b')],
        ['image', image_url(3)],
        ['audio', audio_url],
        ['image', poster_url],
      ]
      expect(item.media.last['origin']).to eq 'html_img'
    end

    it 'stops at 12 candidates in document order when images and videos overflow' do
      parts = (1..8).flat_map do |number|
        [
          %(<img src="https://cdn.example/cap-#{number}.png" alt="#{number}">),
          %(<video src="https://cdn.example/cap-#{number}.mp4"></video>),
        ]
      end
      item = parse_item(<<~XML)
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Cap</title><link>https://example.com</link>
          <item>
            <guid>cap</guid><title>Cap</title><link>https://example.com/cap</link>
            <description><![CDATA[#{parts.join}]]></description>
          </item>
        </channel></rss>
      XML

      expect(ExternalBridge::RSS::Limits::MAX_MEDIA_CANDIDATES).to eq 12
      expect(item.media.size).to eq 12
      expect(item.media.map { |row| row['url'] }).to eq (1..6).flat_map { |number|
        ["https://cdn.example/cap-#{number}.png", "https://cdn.example/cap-#{number}.mp4"]
      }
      expect(item.media.map { |row| row['url'] }).not_to include('https://cdn.example/cap-7.png')
    end

    it 'keeps every video file and only one iframe when the article has several players' do
      item = parse_item(<<~XML)
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
          <title>Players</title><link>https://watch.example.com</link>
          <item>
            <title>Several players</title>
            <link>https://watch.example.com/watch?id=abc123</link>
            <media:content url="https://cdn.example/mixed-secret/clip-a.mp4" medium="video" type="video/mp4"/>
            <embed><![CDATA[
              <iframe src="https://player.example.com/embed/abc123"></iframe>
              <iframe src="https://www.example.com/embed/abc123"></iframe>
            ]]></embed>
            <media:content url="https://cdn.example/mixed-secret/clip-b.mp4" medium="video" type="video/mp4"/>
          </item>
        </channel></rss>
      XML

      embeds = item.media.select { |row| row['kind'] == 'embed' }
      expect(embeds.size).to eq 1
      expect(embeds.first['url']).to eq 'https://player.example.com/embed/abc123'
      expect(item.media.map { |row| row['url'] }).to eq [
        'https://cdn.example/mixed-secret/clip-a.mp4',
        'https://player.example.com/embed/abc123',
        'https://cdn.example/mixed-secret/clip-b.mp4',
      ]
      expect(item.media.to_json).not_to include('www.example.com/embed/abc123')
      expect(ExternalBridge::RSS::Limits::MAX_EMBED_SCAN).to eq 4
    end
  end

  describe 'owner REST sequence' do
    let(:bundle) { external_project_for(user, body: 'Secret mixed article') }

    before do
      store_candidates(bundle, parse_item(mixed_feed).media)
    end

    it 'shows three local images, then the two videos and the audio, only to the owner' do
      fetch_images(bundle, [image_url(1), image_url(2), image_url(3)])

      body = owner_json(user, bundle[:status].reload)
      sequence = body[:fedibird_external][:sequence]
      expect(sequence.map { |row| [row[:type], row[:delivery], row[:url]] }).to eq [
        ['image', 'local', nil],
        ['video', 'remote', video_url('a')],
        ['image', 'local', nil],
        ['video', 'remote', video_url('b')],
        ['image', 'local', nil],
        ['audio', 'remote', audio_url],
      ]
      expect(sequence.map { |row| row[:position] }).to eq [0, 1, 2, 3, 4, 5]
      expect(body[:media_attachments].map { |row| row[:type] }).to eq %w(image image image)
      expect(body[:media_attachments].map { |row| row[:description] }).to eq %w(One Two Three)
      expect(body[:fedibird_external][:media].map { |row| row[:url] }).to eq [video_url('a'), video_url('b'), audio_url]
      expect(body.to_json).not_to include(poster_url)
      expect(body.to_json).not_to include(image_url(1))

      [stranger, roommate].each do |viewer|
        get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(viewer)
        expect(response).to have_http_status(404)
        expect(response.body).not_to include('Secret mixed article')
        expect(response.body).not_to include('mixed-secret')
      end
    end

    it 'omits images past the local attachment cap and still returns unsaved video and audio' do
      previous = Setting.attachments_max
      Setting.attachments_max = 2
      fetch_images(bundle, [image_url(1), image_url(2), image_url(3)])

      body = owner_json(user, bundle[:status].reload)
      sequence = body[:fedibird_external][:sequence]
      expect(sequence.map { |row| [row[:type], row[:delivery], row[:url]] }).to eq [
        ['image', 'local', nil],
        ['video', 'remote', video_url('a')],
        ['image', 'local', nil],
        ['video', 'remote', video_url('b')],
        ['audio', 'remote', audio_url],
      ]
      expect(body[:media_attachments].map { |row| row[:description] }).to eq %w(One Two)
      expect(body.to_json).not_to include(image_url(3))
      expect(bundle[:status].media_attachments.count).to eq 2
    ensure
      Setting.attachments_max = previous
    end

    it 'clamps the saved-file cap to the hard attachment limit' do
      previous = Setting.attachments_max
      sync = ExternalBridge::RSS::Media::Sync.new(bundle[:marker], bundle[:resource])
      Setting.attachments_max = 50
      expect(sync.send(:attachment_limit)).to eq MediaAttachment::ATTACHMENTS_LIMIT
      expect(MediaAttachment::ATTACHMENTS_LIMIT).to eq 20
      Setting.attachments_max = 2
      expect(sync.send(:attachment_limit)).to eq 2
      Setting.attachments_max = 0
      expect(sync.send(:attachment_limit)).to eq 4
    ensure
      Setting.attachments_max = previous
    end

    it 'keeps one saved video and one remote video, then audio and a single embed' do
      Setting.external_bridge_rss_video_policy = 'hybrid'
      bundle[:resource].update!(
        canonical_url: 'https://watch.example.com/watch?id=abc123',
        media_candidates: hybrid_candidates
      )
      link_saved_video!(bundle, video_url('saved'))

      body = owner_json(user, bundle[:status].reload)
      sequence = body[:fedibird_external][:sequence]
      expect(sequence.map { |row| [row[:type], row[:delivery], row[:url]] }).to eq [
        ['video', 'local', nil],
        ['video', 'remote', video_url('b')],
        ['audio', 'remote', audio_url],
        ['embed', 'remote', 'https://player.example.com/embed/abc123'],
      ]
      expect(body[:media_attachments].map { |row| row[:type] }).to eq ['video']
      expect(body[:fedibird_external][:media].map { |row| [row[:type], row[:url]] }).to eq [
        ['video', video_url('b')],
        ['audio', audio_url],
      ]
      expect(body.to_json).not_to include(video_url('saved'))
      expect(body.to_json).to include(video_url('b'))
    ensure
      Setting.external_bridge_rss_video_policy = 'remote'
    end

    it 'does not list a saved poster in the gallery sequence' do
      fetch_images(bundle, [image_url(1), image_url(2), image_url(3)])
      candidates = bundle[:resource].media_candidates + [poster_candidate]
      bundle[:resource].update!(media_candidates: candidates)
      link_poster!(bundle)

      body = owner_json(user, bundle[:status].reload)
      # This link is poster-only, so the article image past the saved gallery
      # does not borrow its attachment id.
      expect(body[:fedibird_external][:sequence].map { |row| row[:type] }).to eq %w(image video image video image audio)
      expect(body[:media_attachments].map { |row| row[:description] }).to eq %w(One Two Three)
      expect(body.to_json).not_to include(poster_url)
      expect(bundle[:status].reload.ordered_media_attachments.map(&:description)).to eq %w(One Two Three)
      expect(bundle[:status].media_attachments.count).to eq 4
    end
  end

  describe 'public HTML, ActivityPub, and oEmbed' do
    let(:bundle) { external_project_for(user, body: 'Secret mixed article') }

    before do
      store_candidates(bundle, parse_item(mixed_feed).media)
      fetch_images(bundle, [image_url(1), image_url(2), image_url(3)])
      allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
      allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
        with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
      end
    end

    it 'does not print remote media or the article for anyone except the signed-in owner HTML page' do
      secret_paths = [video_url('a'), video_url('b'), audio_url, poster_url, image_url(1)]

      get "/@#{user.account.username}/#{bundle[:status].id}"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Secret mixed article')
      secret_paths.each { |url| expect(response.body).not_to include(url) }

      get "/@#{user.account.username}/#{bundle[:status].id}/embed"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('mixed-secret')

      get "/users/#{user.account.username}/statuses/#{bundle[:status].id}", headers: { 'Accept' => 'application/activity+json' }
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('mixed-secret')

      get '/api/oembed', params: { url: short_account_status_url(user.account, bundle[:status]) }
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('mixed-secret')

      sign_in stranger
      get "/@#{user.account.username}/#{bundle[:status].id}"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Secret mixed article')
      sign_out stranger

      sign_in user
      get "/@#{user.account.username}/#{bundle[:status].id}"
      expect(response).to have_http_status(200)
      expect(response.body).to include('Secret mixed article')
      secret_paths.each { |url| expect(response.body).not_to include(url) }

      get "/@#{user.account.username}/#{bundle[:status].id}/embed"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('mixed-secret')

      get "/users/#{user.account.username}/statuses/#{bundle[:status].id}", headers: { 'Accept' => 'application/activity+json' }
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Secret mixed article')
    end
  end

  def parse_item(xml)
    ExternalBridge::RSS::Parser.parse!(xml).items.first
  end

  def mixed_feed
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
        <title>Mixed</title><link>https://example.com</link>
        <item>
          <title>Mixed story</title>
          <guid>mixed-story</guid>
          <link>https://example.com/mixed-story</link>
          <media:thumbnail url="#{poster_url}"/>
          <media:content url="#{image_url(1)}" medium="image" type="image/png" description="One"/>
          <media:content url="#{video_url('a')}" medium="video" type="video/mp4" description="Clip A"/>
          <media:content url="#{image_url(2)}" medium="image" type="image/png" description="Two"/>
          <media:content url="#{video_url('b')}" medium="video" type="video/mp4" description="Clip B"/>
          <media:content url="#{image_url(3)}" medium="image" type="image/png" description="Three"/>
          <enclosure url="#{audio_url}" type="audio/mpeg" length="20"/>
          <description><![CDATA[Secret mixed article<img src="#{poster_url}" alt="Poster duplicate"><img src="#{image_url(1)}" alt="One again">]]></description>
        </item>
      </channel></rss>
    XML
  end

  def image_url(number)
    "https://cdn.example/mixed-secret/image-#{number}.png"
  end

  def video_url(name)
    "https://cdn.example/mixed-secret/clip-#{name}.mp4"
  end

  def audio_url
    'https://cdn.example/mixed-secret/talk.mp3'
  end

  def poster_url
    'https://cdn.example/mixed-secret/poster.jpg'
  end

  def store_candidates(world, media)
    world[:resource].update!(
      canonical_url: 'https://example.com/mixed-story',
      media_candidates: media,
      media_revision: 'mixed-1'
    )
  end

  def fetch_images(world, urls)
    urls.each do |url|
      stub_request(:get, url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
      ExternalBridge::RSS::Media::Fetch.new.call(
        world[:resource].id,
        world[:resource].media_revision,
        ExternalBridge::RSS::MediaDigest.url_digest(url)
      )
    end
  end

  def owner_json(owner, status)
    get "/api/v1/statuses/#{status.id}", headers: auth_headers_for(owner)
    expect(response).to have_http_status(200)
    body_as_json
  end

  def hybrid_candidates
    [
      { 'url' => video_url('saved'), 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/mp4', 'position' => 0, 'description' => 'Saved' },
      { 'url' => video_url('b'), 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/mp4', 'position' => 1, 'description' => 'Remote' },
      { 'url' => audio_url, 'kind' => 'audio', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'audio/mpeg', 'position' => 2, 'description' => 'Talk' },
      { 'url' => 'https://player.example.com/embed/abc123', 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'position' => 3 },
    ]
  end

  def link_saved_video!(world, url)
    digest = ExternalBridge::RSS::MediaDigest.url_digest(url)
    asset = ExternalMediaAsset.create!(url_digest: digest, kind: 'video', state: 'failed')
    attachment = MediaAttachment.create!(
      account: world[:status].account,
      status: world[:status],
      file: attachment_fixture('attachment.jpg'),
      remote_url: ''
    )
    attachment.update_columns(type: MediaAttachment.types[:video])
    ExternalProjectionAttachment.create!(
      external_status_projection: world[:marker],
      external_media_asset: asset,
      media_attachment: attachment,
      position: 0,
      kind: 'video'
    )
  end

  def poster_candidate
    { 'url' => poster_url, 'kind' => 'image', 'role' => 'poster', 'origin' => 'rss_thumb', 'position' => 6 }
  end

  def link_poster!(world)
    digest = ExternalBridge::RSS::MediaDigest.url_digest(poster_url)
    asset = ExternalMediaAsset.create!(url_digest: digest, kind: 'image', state: 'failed')
    attachment = MediaAttachment.create!(
      account: world[:status].account,
      status: world[:status],
      file: attachment_fixture('attachment.jpg'),
      description: 'Poster',
      remote_url: ''
    )
    ExternalProjectionAttachment.create!(
      external_status_projection: world[:marker],
      external_media_asset: asset,
      media_attachment: attachment,
      position: 6,
      kind: 'poster'
    )
  end
end
# rubocop:enable Metrics/BlockLength
