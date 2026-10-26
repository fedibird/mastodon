# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS article media' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/media.xml' }
  let(:image_url) { 'https://cdn.example/story.png' }
  let(:video_url) { 'https://cdn.example/story.mp4' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    enable_external_bridge_rss!(user, other)
    stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, video_url).to_return(status: 200, body: 'video-bytes', headers: { 'Content-Type' => 'video/mp4', 'Content-Length' => '11' })
  end

  def item_xml(media: false)
    description = media ? %(Plain story<img src="#{image_url}" alt="Story">) : 'Plain story'
    enclosure = media ? %(<enclosure url="#{video_url}" type="video/mp4" length="11"/>) : ''
    <<~XML
      <item>
        <guid>story</guid>
        <title>Story</title>
        <link>https://example.com/story</link>
        <description><![CDATA[#{description}]]></description>
        #{enclosure}
      </item>
    XML
  end

  it 'stores a separate media revision without changing the text revision' do
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    resource = ExternalResource.find_by!(title: 'Story')
    text_revision = resource.revision
    expect(resource.media_candidates).to eq []
    expect(resource.media_revision).to eq ExternalBridge::RSS::MediaDigest::EMPTY

    feed = ExternalBridge::RSS::Parser.parse!(rss_document(item_xml(media: true)))
    response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
    ExternalBridge::RSS::Ingest.new.apply_public!(resource.external_source, feed, response)

    resource.reload
    expect(resource.body).to eq 'Plain story'
    expect(resource.revision).to eq text_revision
    expect(resource.media_revision).not_to eq text_revision
    expect(resource.media_candidates.map { |row| row['kind'] }).to eq %w(image video)
  end

  it 'attaches a shared image once and never downloads the video' do
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml(media: true)))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)

    expect(a_request(:get, video_url)).not_to have_been_made
    expect(a_request(:get, image_url)).to have_been_made.once
    expect(ExternalMediaAsset.where(kind: 'video')).to be_empty
    expect(ExternalMediaAsset.where(kind: 'image', state: 'ready').count).to eq 1

    owners = [user, other].map do |subscriber|
      status = Status.find(ExternalStatusProjection.find_by!(user_id: subscriber.id).status_id)
      expect(status.media_attachments.map(&:type)).to eq ['image']
      expect(status.media_attachments.map(&:remote_url)).to eq ['']
      expect(status.media_attachments.map(&:description)).to eq ['Story']
      status
    end
    expect(owners.map { |status| status.media_attachments.map(&:id) }.flatten.uniq.size).to eq 2
  end

  it 'does not attach an image for a revision that is no longer current' do
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    resource = ExternalResource.find_by!(title: 'Story')
    digest = ExternalBridge::RSS::MediaDigest.url_digest(image_url)

    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, 'stale-revision', digest)

    expect(a_request(:get, image_url)).not_to have_been_made
    expect(ExternalMediaAsset.count).to eq 0
    expect(Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id).media_attachments).to be_empty
  end

  it 'removes the attachment and the unreferenced asset when the projection is purged' do
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml(media: true)))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    expect(status.media_attachments.count).to eq 1

    ExternalBridge::ProjectionPurge.purge_status!(status)

    expect(MediaAttachment.where(account_id: user.account_id)).to be_empty
    expect(ExternalProjectionAttachment.count).to eq 0
    expect(ExternalMediaAsset.count).to eq 0
  end
end
