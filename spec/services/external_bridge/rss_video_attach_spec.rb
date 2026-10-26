# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS hybrid video attachment' do
  let(:user) { Fabricate(:user) }
  let(:image_url) { 'https://cdn.example/story.png' }
  let(:video_url) { 'https://cdn.example/clip.webm' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }
  let(:webm) { Rails.root.join('spec', 'fixtures', 'files', 'attachment.webm').binread }
  let(:bundle) { external_project_for(user) }

  before do
    enable_external_bridge_rss!(user)
    Setting.external_bridge_rss_video_policy = 'hybrid'
    Setting.external_bridge_rss_video_max_download_mib = 20
    Rails.cache.clear
    bundle[:resource].update!(
      media_revision: 'media-mixed',
      media_candidates: [
        { 'url' => image_url, 'kind' => 'image', 'role' => 'attachment', 'origin' => 'html_img', 'description' => 'Still', 'position' => 0 },
        { 'url' => video_url, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/webm', 'description' => 'Clip', 'length_hint' => webm.bytesize, 'position' => 1 },
      ]
    )
    stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:head, video_url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'video/webm', 'Content-Length' => webm.bytesize.to_s })
    stub_request(:get, video_url).to_return(status: 200, body: webm, headers: { 'Content-Type' => 'video/webm', 'Content-Length' => webm.bytesize.to_s })
  end

  after do
    Setting.external_bridge_rss_video_policy = 'remote'
    Setting.external_bridge_rss_video_max_download_mib = 20
    Rails.cache.clear
  end

  def fetch(url)
    ExternalBridge::RSS::Media::Fetch.new.call(bundle[:resource].id, 'media-mixed', ExternalBridge::RSS::MediaDigest.url_digest(url))
  end

  def owner_json(status)
    REST::StatusSerializer.new(status, scope: user, scope_name: :current_user).serializable_hash.deep_symbolize_keys
  end

  it 'stores a real WebM beside the image and stops advertising it as remote' do
    fetch(image_url)
    fetch(video_url)

    status = bundle[:status].reload
    expect(status.media_attachments.map(&:type)).to eq %w(image gifv)
    expect(status.media_attachments.map(&:remote_url).uniq).to eq ['']
    expect(a_request(:get, video_url)).to have_been_made.once

    body = owner_json(status)

    expect(body[:media_attachments].map { |row| row[:type] }).to eq %w(image gifv)
    expect(body[:fedibird_external][:sequence].map { |row| [row[:type], row[:delivery]] }).to eq [
      ['image', 'local'],
      ['video', 'local'],
    ]
    expect(body[:fedibird_external]).not_to have_key(:media)
  end

  it 'keeps the remote video when the saved file cannot be attached' do
    stub_request(:get, video_url).to_return(status: 200, body: 'not-a-video', headers: { 'Content-Type' => 'video/webm', 'Content-Length' => '11' })
    stub_request(:head, video_url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'video/webm', 'Content-Length' => '11' })
    bundle[:resource].update!(media_candidates: [
      { 'url' => video_url, 'kind' => 'video', 'mime_hint' => 'video/webm', 'length_hint' => 11, 'position' => 0, 'description' => 'Clip' },
    ])

    fetch(video_url)

    body = owner_json(bundle[:status].reload)

    expect(bundle[:status].media_attachments).to be_empty
    expect(body[:fedibird_external][:media]).to include(hash_including(type: 'video', url: video_url, delivery: 'remote'))
  end

  it 'asks again after a 503 and does not ask again after a size refusal' do
    stub_request(:head, video_url).to_return(status: 503, body: '', headers: { 'Content-Type' => 'video/webm' })
    fetch(video_url)
    asset = ExternalMediaAsset.find_by!(url_digest: ExternalBridge::RSS::MediaDigest.url_digest(video_url))
    expect(asset.attempt_count).to eq 1
    expect(asset.exhausted_for?('media-mixed')).to be false

    fetch(video_url)
    expect(asset.reload.attempt_count).to eq 2
    expect(a_request(:head, video_url)).to have_been_made.twice

    bundle[:resource].update!(media_candidates: [
      { 'url' => video_url, 'kind' => 'video', 'mime_hint' => 'video/webm', 'length_hint' => 30.megabytes, 'position' => 0 },
    ])
    ExternalMediaAsset.where(url_digest: asset.url_digest).delete_all
    fetch(video_url)
    refused = ExternalMediaAsset.find_by!(url_digest: asset.url_digest)
    expect(refused.exhausted_for?('media-mixed')).to be true
    expect(a_request(:head, video_url)).to have_been_made.twice
  end
end
