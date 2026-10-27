# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS embed poster' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:stranger) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/embed.xml' }
  let(:player_url) { 'https://player.example.com/embed/abc123' }
  let(:large_url) { 'https://images.example/assets/original.mp4/plain/ex:1/rs:fit:320:240?hash=aaa&validto=10' }
  let(:small_url) { 'https://images.example/assets/original.mp4/plain/ex:1/rs:fit:180:135?hash=aaa&validto=10' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    enable_external_bridge_rss!(user, other, stranger)
    Rails.cache.clear
  end

  def large_fetch
    ExternalBridge::RSS::PosterURL.pair(large_url).fetch
  end

  def small_fetch
    ExternalBridge::RSS::PosterURL.pair(small_url).fetch
  end

  def item_xml(large: large_url, small: small_url)
    <<~XML
      <item>
        <title>Example video</title>
        <link>https://watch.example.com/watch?id=abc123</link>
        <pubDate>Tue, 27 Oct 2026 12:00:00 +0000</pubDate>
        <duration>1081</duration>
        <thumb>#{small.gsub('&', '&amp;')}</thumb>
        <thumb_large>#{large.gsub('&', '&amp;')}</thumb_large>
        <embed><![CDATA[<iframe src="#{player_url}" frameborder="0"></iframe>]]></embed>
        <keywords><![CDATA[topic one,topic two]]></keywords>
      </item>
    XML
  end

  def owner_json(owner)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: owner.id).status_id)
    REST::StatusSerializer.new(status, scope: owner, scope_name: :current_user).serializable_hash.deep_symbolize_keys
  end

  it 'stores the poster as an image, shares it, and keeps the player remote' do
    stub_request(:get, large_fetch).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
    Setting.external_bridge_rss_video_policy = 'hybrid'

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)

    expect(a_request(:get, large_fetch)).to have_been_made.once
    expect(a_request(:get, player_url)).not_to have_been_made
    expect(ExternalMediaAsset.where(kind: 'video')).to be_empty
    expect(ExternalMediaAsset.where(kind: 'image', state: 'ready').count).to eq 1

    body = owner_json(user)
    sequence = body[:fedibird_external][:sequence]
    expect(sequence.map { |row| row[:type] }).to eq ['embed']
    expect(sequence.first[:url]).to eq player_url
    expect(sequence.first[:duration]).to eq 1081
    expect(sequence.first[:poster]).to be_present
    expect(sequence.first[:poster]).not_to include('images.example')
    expect(body[:fedibird_external]).not_to have_key(:media)
    expect(body[:fedibird_external][:keywords]).to eq ['topic one', 'topic two']
    expect(body[:media_attachments]).to eq []
    expect(body[:content]).not_to include(player_url)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    expect(status.ordered_media_attachments).to eq []
    expect(status.media_attachments.map(&:type)).to eq ['image']
    expect { ActivityPub::NoteSerializer.new(status).type }.to raise_error(Status::UnreleasedActivityObject)
    stranger_body = REST::StatusSerializer.new(status, scope: stranger, scope_name: :current_user).serializable_hash.deep_symbolize_keys
    expect(stranger_body).not_to have_key(:fedibird_external)
  ensure
    Setting.external_bridge_rss_video_policy = 'remote'
  end

  it 'falls back to the smaller poster when the large URL is forbidden' do
    stub_request(:get, large_fetch).to_return(status: 403, body: '')
    stub_request(:get, small_fetch).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    expect(a_request(:get, small_fetch)).to have_been_made.once
    expect(owner_json(user)[:fedibird_external][:sequence].first[:poster]).to be_present
    expect(ExternalMediaAsset.where(kind: 'video')).to be_empty
  end

  it 'does not store a video response from an image transform URL' do
    stub_request(:get, large_fetch).to_return(status: 200, body: 'not-video', headers: { 'Content-Type' => 'video/mp4' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml(small: '')))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    body = owner_json(user)
    expect(body[:fedibird_external][:sequence].first[:type]).to eq 'embed'
    expect(body[:fedibird_external][:sequence].first).not_to have_key(:poster)
    expect(ExternalMediaAsset.ready).to be_empty
    expect(a_request(:get, player_url)).not_to have_been_made
  end

  it 'retries a new signature without changing the media revision and then stops on the same expired URL' do
    resource = nil
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml(small: '')))
    stub_request(:get, large_fetch).to_return(status: 403, body: '')
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    resource = ExternalResource.find_by!(title: 'Example video')
    revision = resource.media_revision
    digest = ExternalBridge::RSS::MediaDigest.url_digest(resource.media_candidates.find { |row| row['role'] == 'poster' }['url'])

    2.times { ExternalBridge::RSS::Media::Fetch.new.call(resource.id, revision, digest) }
    expect(a_request(:get, large_fetch)).to have_been_made.times(3)

    refreshed = large_url.sub('hash=aaa', 'hash=bbb')
    WebMock.reset_executed_requests!
    stub_request(:get, ExternalBridge::RSS::PosterURL.pair(refreshed).fetch).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    feed = ExternalBridge::RSS::Parser.parse!(rss_document(item_xml(large: refreshed)))
    response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
    ExternalBridge::RSS::Ingest.new.apply_public!(resource.external_source, feed, response)
    resource.reload
    expect(resource.media_revision).to eq revision
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest)

    expect(a_request(:get, ExternalBridge::RSS::PosterURL.pair(refreshed).fetch)).to have_been_made.once
    expect(ExternalMediaAsset.ready.where(kind: 'image').count).to eq 1
  end

  it 'keeps the shared poster when one subscriber leaves and releases it when the other leaves' do
    stub_request(:get, large_fetch).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)
    asset_id = ExternalMediaAsset.find_by!(kind: 'image').id
    subscription_id = ExternalStatusProjection.find_by!(user_id: user.id).external_subscription_id

    ExternalBridge::RSS::Unsubscribe.new.call(user: user, subscription_id: subscription_id)

    expect(ExternalMediaAsset.find_by(id: asset_id)&.ready?).to be true
    expect(owner_json(other)[:fedibird_external][:sequence].first[:poster]).to be_present

    other_subscription = ExternalStatusProjection.find_by!(user_id: other.id).external_subscription_id
    ExternalBridge::RSS::Unsubscribe.new.call(user: other, subscription_id: other_subscription)
    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(ExternalMediaAsset.find_by(id: asset_id)).to be_nil
  end

  it 'projects a guid-less viewkey item and same-site player through the owner sequence' do
    article = 'https://watch.example.com/view_video.php?viewkey=abc123'
    player = 'https://www.example.com/embed/abc123'
    image = 'https://images.example/large.png'
    feed = 'https://feeds.example/viewkey.xml'
    xml = <<~XML
      <item>
        <title>Viewkey video</title>
        <link>#{article}</link>
        <duration>1081</duration>
        <thumb_large>#{image}</thumb_large>
        <thumbnail>https://images.example/small.png</thumbnail>
        <embed><![CDATA[<iframe src="#{player}"></iframe>]]></embed>
      </item>
    XML
    stub_request(:get, image).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed).to_return(status: 200, body: rss_document(xml))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed)

    resource = ExternalResource.find_by!(title: 'Viewkey video')
    sequence = owner_json(user)[:fedibird_external][:sequence]
    expect(resource.canonical_url).to eq article
    expect(sequence.first[:type]).to eq 'embed'
    expect(sequence.first[:url]).to eq player
    expect(sequence.first[:duration]).to eq 1081
    expect(sequence.first[:poster]).to be_present
    expect(a_request(:get, player)).not_to have_been_made
  end

  it 'keeps one attachment when the same image changes between gallery and poster' do
    image = 'https://cdn.example/still.png'
    feed = 'https://feeds.example/role.xml'
    article = 'https://watch.example.com/watch?id=abc123'
    notices = 0
    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!) { notices += 1 }
    stub_request(:get, image).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed).to_return(status: 200, body: rss_document(role_xml(article, image)))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    attachment_id = status.media_attachments.pick(:id)
    expect(status.ordered_media_attachments.map(&:id)).to eq [attachment_id]
    expect(ExternalProjectionAttachment.find_by!(media_attachment_id: attachment_id).kind).to eq 'image'

    seen = notices
    allow(Rails.cache).to receive(:delete).and_call_original
    refresh_role!(feed, role_xml(article, image, poster: true))

    status.reload
    expect(status.media_attachments.pluck(:id)).to eq [attachment_id]
    expect(ExternalProjectionAttachment.where(media_attachment_id: attachment_id).pluck(:kind)).to eq ['poster']
    expect(status.ordered_media_attachments).to eq []
    expect(owner_json(user)[:media_attachments]).to eq []
    expect(owner_json(user)[:fedibird_external][:sequence].map { |row| row[:type] }).to eq ['embed']
    expect(ExternalMediaAsset.where(kind: 'image', state: 'ready').count).to eq 1
    expect(a_request(:get, image)).to have_been_made.once
    expect(notices).to be > seen
    expect(Rails.cache).to have_received(:delete).with("statuses/#{status.id}").at_least(:once)

    refresh_role!(feed, role_xml(article, image))

    expect(status.reload.ordered_media_attachments.map(&:id)).to eq [attachment_id]
    expect(ExternalProjectionAttachment.where(media_attachment_id: attachment_id).pluck(:kind)).to eq ['image']
    expect(owner_json(user)[:media_attachments].map { |row| row[:id] }).to eq [attachment_id.to_s]
    expect(status.media_attachments.count).to eq 1
    expect(a_request(:get, image)).to have_been_made.once
  end

  it 'accepts a signed poster URL only on the poster image fetch' do
    signed = large_fetch
    expect { ExternalBridge::RSS::Media::ImageFetch.new.call(signed) }.to raise_error(ExternalBridge::Error)
    expect(a_request(:get, signed)).not_to have_been_made

    stub_request(:get, signed).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    result = ExternalBridge::RSS::Media::ImageFetch.new.call(signed, poster: true)

    expect(result.content_type).to eq 'image/png'
    expect(a_request(:get, signed)).to have_been_made.once
  end

  def role_xml(article, image, poster: false)
    media = if poster
              %(<thumb_large>#{image}</thumb_large><embed><![CDATA[<iframe src="#{player_url}"></iframe>]]></embed>)
            else
              %(<enclosure url="#{image}" type="image/png"/>)
            end
    <<~XML
      <item>
        <title>Example</title>
        <link>#{article}</link>
        <description>Same words</description>
        #{media}
      </item>
    XML
  end

  def refresh_role!(feed, xml)
    resource = ExternalResource.find_by!(title: 'Example')
    parsed = ExternalBridge::RSS::Parser.parse!(rss_document(xml))
    response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed)
    ExternalBridge::RSS::Ingest.new.apply_public!(resource.external_source, parsed, response)
    subscription = ExternalSubscription.find_by!(user_id: user.id)
    ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: [resource.reload])
  end
end
