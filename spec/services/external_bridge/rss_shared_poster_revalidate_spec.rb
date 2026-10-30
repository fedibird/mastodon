# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS shared poster revalidation' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/shared-poster.xml' }
  let(:player_url) { 'https://player.example.com/embed/abc123' }
  let(:large_url) { 'https://images.example/assets/original.mp4/plain/ex:1/rs:fit:320:240?hash=aaa&validto=10' }
  let(:small_url) { 'https://images.example/assets/original.mp4/plain/ex:1/rs:fit:180:135?hash=aaa&validto=10' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }
  let(:jpeg) { Rails.root.join('spec', 'fixtures', 'files', 'attachment.jpg').binread }

  before do
    enable_external_bridge_rss!(user)
    redis.del('external_bridge:rss_media:host:images.example')
  end

  def logical(url)
    ExternalBridge::RSS::PosterURL.pair(url).logical
  end

  def signed(url)
    ExternalBridge::RSS::PosterURL.pair(url).fetch
  end

  def item_xml(large: large_url, small: nil)
    image = if small
              %(<img src="#{logical(large)}" srcset="#{logical(large)} 1x, #{logical(small)} 2x" alt="Still frame">)
            else
              %(<img src="#{logical(large)}" alt="Still frame">)
            end
    <<~XML
      <item>
        <guid>story</guid>
        <title>Story</title>
        <link>https://watch.example.com/watch?id=abc123</link>
        <description><![CDATA[#{image}]]></description>
        #{poster_markup(large, small)}
        <embed><![CDATA[<iframe src="#{player_url}"></iframe>]]></embed>
      </item>
    XML
  end

  def poster_markup(large, small)
    if small
      %(<thumb>#{escape_xml(small)}</thumb><thumb_large>#{escape_xml(large)}</thumb_large>)
    else
      %(<thumb>#{escape_xml(large)}</thumb>)
    end
  end

  def escape_xml(url)
    url.gsub('&', '&amp;')
  end

  def publish!(large: large_url, small: nil)
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml(large: large, small: small)))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    ExternalResource.find_by!(title: 'Story')
  end

  def ingest!(large:, small: nil)
    parsed = ExternalBridge::RSS::Parser.parse!(rss_document(item_xml(large: large, small: small)))
    response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
    ExternalBridge::RSS::Ingest.new.apply_public!(ExternalSource.find_by!(canonical_key: feed_url), parsed, response)
    ExternalResource.find_by!(title: 'Story')
  end

  def image_headers(etag, type = 'image/png')
    { 'Content-Type' => type, 'ETag' => %("#{etag.delete('"')}"), 'Last-Modified' => 'Mon, 01 Jan 2024 00:00:00 GMT' }
  end

  def conditional_headers(etag = 'v1')
    { 'If-None-Match' => %("#{etag}"), 'If-Modified-Since' => 'Mon, 01 Jan 2024 00:00:00 GMT' }
  end

  def age!(asset)
    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil, revalidate_attempt: 0)
    asset
  end

  it 'revalidates the signed URL when the article image is listed first' do
    stub_request(:get, signed(large_url)).to_return(status: 200, body: png, headers: image_headers('v1'))
    resource = publish!
    asset = age!(ExternalMediaAsset.find_by!(url_digest: ExternalBridge::RSS::MediaDigest.url_digest(logical(large_url))))
    stub_request(:get, signed(large_url)).with(headers: conditional_headers).to_return(status: 304, body: '')

    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, asset.url_digest)).to eq :not_modified

    expect(a_request(:get, signed(large_url)).with(headers: conditional_headers)).to have_been_made.once
    expect(a_request(:get, logical(large_url))).not_to have_been_made
    expect(asset.reload).to be_ready

    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    stub_request(:get, signed(large_url)).with(headers: conditional_headers).to_return(status: 200, body: jpeg, headers: image_headers('v2', 'image/jpeg'))
    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, asset.url_digest)).to eq :replaced
    replacement = ExternalMediaAsset.find_by!(url_digest: asset.url_digest)
    expect(replacement.fingerprint).to eq Digest::SHA256.hexdigest(jpeg)
    expect(a_request(:get, logical(large_url))).not_to have_been_made
  end

  it 'revalidates a rotated poster signature without calling the logical URL' do
    stub_request(:get, signed(large_url)).to_return(status: 200, body: png, headers: image_headers('v1'))
    resource = publish!
    rotated = large_url.sub('hash=aaa', 'hash=bbb')
    ingest!(large: rotated)
    asset = age!(ExternalMediaAsset.find_by!(url_digest: ExternalBridge::RSS::MediaDigest.url_digest(logical(large_url))))
    stub_request(:get, signed(rotated)).with(headers: conditional_headers).to_return(status: 304, body: '')

    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, asset.url_digest)).to eq :not_modified

    expect(a_request(:get, signed(rotated)).with(headers: conditional_headers)).to have_been_made.once
    expect(a_request(:get, signed(large_url)).with(headers: conditional_headers)).not_to have_been_made
    expect(a_request(:get, logical(large_url))).not_to have_been_made
  end

  it 'revalidates a stored poster fallback through its signed URL' do
    stub_request(:get, signed(large_url)).to_return(status: 404, body: '')
    stub_request(:get, signed(small_url)).to_return(status: 200, body: png, headers: image_headers('v1'))
    resource = publish!(small: small_url)
    asset = age!(ExternalMediaAsset.ready.find_by!(url_digest: ExternalBridge::RSS::MediaDigest.url_digest(logical(small_url))))
    stub_request(:get, signed(small_url)).with(headers: conditional_headers).to_return(status: 304, body: '')

    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, asset.url_digest)).to eq :not_modified

    expect(a_request(:get, signed(small_url)).with(headers: conditional_headers)).to have_been_made.once
    expect(a_request(:get, logical(small_url))).not_to have_been_made
    expect(a_request(:get, logical(large_url))).not_to have_been_made
  end
end
