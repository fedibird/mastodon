# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS image candidate fallback' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/fallback.xml' }
  let(:webp_url) { 'https://cdn.example/a.webp' }
  let(:png_url) { 'https://cdn.example/a.png' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    enable_external_bridge_rss!(user)
    redis.del('external_bridge:rss_media:host:cdn.example')
  end

  it 'attaches the next image after a 404 and does not attach twice' do
    stub_feed(webp: { status: 404, body: '', headers: { 'Content-Type' => 'text/plain' } }, png: png_response('"png-1"'))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    expect(resource.media_candidates.first['url']).to eq webp_url
    expect(resource.media_candidates.first['fallbacks']).to eq [png_url]
    expect(resource.media_revision).to eq ExternalBridge::RSS::MediaDigest.hexdigest(resource.media_candidates)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    expect(status.media_attachments.count).to eq 1
    expect(status.media_attachments.first.file_content_type).to eq 'image/png'
    expect(status.media_attachments.first.description).to eq 'Story'
    expect(ExternalMediaAsset.find_by(url_digest: digest(png_url))).to be_ready
    rejected = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    expect(rejected.failure_code).to eq 'alternate_selected'
    expect(rejected.file_file_name).to be_nil
    sequence = ExternalBridge::RSS::Media::Sequence.for(ExternalStatusProjection.find_by!(user_id: user.id))
    expect(sequence.size).to eq 1
    expect(sequence.first[:delivery]).to eq 'local'

    ExternalBridge::RSS::Media::Sync.enqueue!(resource)
    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'tries the next URL when the first body is not an image' do
    stub_feed(
      webp: { status: 200, body: 'not-an-image', headers: { 'Content-Type' => 'image/webp' } },
      png: png_response
    )

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    expect(ExternalMediaAsset.ready.find_by(url_digest: digest(png_url))).to be_present
    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'tries the next URL after a timeout and records a 404 when every URL fails' do
    stub_feed(webp: { status: 404, body: '' }, png: { status: 404, body: '' })
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    expect(ExternalMediaAsset.find_by!(url_digest: digest(webp_url)).failure_code).to eq 'http_404'
    expect(Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id).media_attachments).to be_empty

    resource = ExternalResource.find_by!(title: 'Story')
    ExternalMediaAsset.where(url_digest: digest(webp_url)).delete_all
    WebMock.reset_executed_requests!
    stub_request(:get, webp_url).to_timeout
    stub_request(:get, png_url).to_return(png_response)
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(webp_url))

    expect(ExternalMediaAsset.ready.find_by(url_digest: digest(png_url))).to be_present
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'does not request an unsafe fallback or a URL past the attempt cap' do
    urls = (1..5).map { |number| "https://cdn.example/n#{number}.png" }
    candidate = { 'url' => 'http://127.0.0.1/secret.png', 'kind' => 'image', 'fallbacks' => urls + ['javascript:alert(1)'] }
    expect(ExternalBridge::RSS::Media::ImageAttempts.urls(candidate)).to eq urls.first(ExternalBridge::RSS::Limits::MAX_IMAGE_FETCH_ATTEMPTS)

    resource = publish_candidate(candidate.merge('url' => urls.first, 'fallbacks' => urls.drop(1)))
    urls.each { |url| stub_request(:get, url).to_return(status: 404, body: '') }
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(urls.first))

    expect(a_request(:get, urls[3])).to have_been_made.once
    expect(a_request(:get, urls[4])).not_to have_been_made
    expect(a_request(:get, 'http://127.0.0.1/secret.png')).not_to have_been_made
  end

  it 'stops on the host budget before the next candidate' do
    resource = publish_candidate('url' => webp_url, 'kind' => 'image', 'fallbacks' => [png_url], 'description' => 'Story')
    calls = []
    fetcher = instance_double(ExternalBridge::RSS::Media::ImageFetch)
    allow(ExternalBridge::RSS::Media::ImageFetch).to receive(:new).and_return(fetcher)
    allow(fetcher).to receive(:call) do |url, **_|
      calls << url
      raise ExternalBridge::Error, :rate_limited
    end

    expect do
      ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(webp_url))
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'rate_limited' }
    expect(calls).to eq [webp_url]
  end

  it 'revalidates the URL that was actually stored' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    asset = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    stub_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' }).to_return(status: 304, body: '')

    result = ExternalBridge::RSS::Media::Revalidate.call(ExternalResource.find_by!(title: 'Story').id, asset.url_digest)

    expect(result).to eq :not_modified
    expect(a_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' })).to have_been_made.once
    expect(a_request(:get, webp_url).with(headers: { 'If-None-Match' => '"png-1"' })).not_to have_been_made
  end

  def stub_feed(webp:, png:)
    stub_request(:get, webp_url).to_return(webp)
    stub_request(:get, png_url).to_return(png)
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
  end

  def png_response(etag = nil)
    headers = { 'Content-Type' => 'image/png' }
    headers['ETag'] = etag if etag
    { status: 200, body: png, headers: headers }
  end

  def item_xml
    <<~XML
      <item>
        <guid>story</guid>
        <title>Story</title>
        <link>https://example.com/story</link>
        <description><![CDATA[
          <picture>
            <source type="image/webp" srcset="#{webp_url} 800w">
            <source type="image/png" srcset="#{png_url} 800w">
            <img src="#{png_url}" alt="Story">
          </picture>
        ]]></description>
      </item>
    XML
  end

  def digest(url)
    ExternalBridge::RSS::MediaDigest.url_digest(url)
  end

  def publish_candidate(candidate)
    source = ExternalSource.create!(
      protocol: 'rss', canonical_key: feed_url, title: 'Feed', site_url: 'https://example.com',
      etag: 'W/"f"', fetched_at: Time.current, checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source, protocol: 'rss', canonical_key: "feed:#{feed_url}\nitem:story",
      title: 'Story', body: 'Story', canonical_url: 'https://example.com/story', revision: 'rev',
      media_candidates: [candidate], media_revision: 'rev-media', published_at: Time.current, fetched_at: Time.current
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    status = Status.create!(account: user.account, text: 'Story', visibility: :external, searchability: :personal, external_projection: true, local: true)
    ExternalStatusProjection.create!(
      user_id: user.id, account_id: user.account_id, external_source_id: source.id,
      external_subscription_id: subscription.id, external_resource_id: resource.id,
      status_id: status.id, last_seen_revision: resource.revision
    )
    resource
  end
end
