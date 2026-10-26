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

  it 'does not convert a broken video again on the next refresh, and keeps an existing image' do
    fetch(image_url)
    image_id = bundle[:status].reload.media_attachments.pick(:id)
    notifications = 0
    creates = 0
    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!) { notifications += 1 }
    allow(MediaAttachment).to receive(:create!) do
      creates += 1
      raise Paperclip::Error, 'unsupported file'
    end
    bundle[:resource].update!(media_candidates: [
      { 'url' => video_url, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/webm', 'description' => 'Clip', 'length_hint' => webm.bytesize, 'position' => 0 },
      { 'url' => image_url, 'kind' => 'image', 'role' => 'attachment', 'origin' => 'html_img', 'description' => 'Still', 'position' => 1 },
    ])

    fetch(video_url)

    asset = ExternalMediaAsset.find_by!(url_digest: ExternalBridge::RSS::MediaDigest.url_digest(video_url))
    expect(asset).to be_processing_failed
    expect(asset.attempt_count).to eq 1
    expect(asset).to be_processing_blocked('media-mixed')
    expect(bundle[:status].reload.media_attachments.map(&:id)).to eq [image_id]
    expect(creates).to eq 1
    expect(notifications).to eq 0
    body = owner_json(bundle[:status])
    expect(body[:fedibird_external][:sequence].map { |row| [row[:type], row[:delivery]] }).to eq [
      ['video', 'remote'],
      ['image', 'local'],
    ]

    bundle[:status].update_columns(text: ExternalBridge::RSS::Excerpt.for(bundle[:resource]))
    bundle[:marker].update!(last_seen_revision: bundle[:resource].revision, last_seen_media_revision: bundle[:resource].media_revision)
    ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])
    ExternalBridge::RSS::Media::Sync.attach_ready!(bundle[:marker].reload, bundle[:resource].reload)
    expect(creates).to eq 1
    expect(notifications).to eq 0
    expect(bundle[:status].reload.media_attachments.map(&:id)).to eq [image_id]

    travel 16.seconds do
      ExternalBridge::RSS::Media::Sync.enqueue!(bundle[:resource].reload, videos: false)
    end
    expect(creates).to eq 2
    expect(asset.reload.attempt_count).to eq 2
    expect(bundle[:status].reload.media_attachments.map(&:id)).to eq [image_id]
    expect(asset.file_file_name).to be_present
    expect(a_request(:get, video_url)).to have_been_made.once
    expect(notifications).to eq 0
  end

  it 'reorders two saved images without dropping either file' do
    other_url = 'https://cdn.example/other.png'
    stub_request(:get, other_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    bundle[:resource].update!(
      media_revision: 'media-order',
      media_candidates: [
        { 'url' => image_url, 'kind' => 'image', 'description' => 'First', 'position' => 0 },
        { 'url' => other_url, 'kind' => 'image', 'description' => 'Second', 'position' => 1 },
      ]
    )
    fetch = lambda do |url|
      ExternalBridge::RSS::Media::Fetch.new.call(bundle[:resource].id, 'media-order', ExternalBridge::RSS::MediaDigest.url_digest(url))
    end
    fetch.call(image_url)
    fetch.call(other_url)
    ids = bundle[:marker].external_projection_attachments.order(:position, :id).pluck(:media_attachment_id)
    expect(ids.size).to eq 2

    bundle[:resource].update!(media_candidates: [
      { 'url' => other_url, 'kind' => 'image', 'description' => 'Second', 'position' => 0 },
      { 'url' => image_url, 'kind' => 'image', 'description' => 'First', 'position' => 1 },
    ])
    ExternalBridge::RSS::Media::Sync.attach_ready!(bundle[:marker].reload, bundle[:resource])

    reordered = bundle[:marker].external_projection_attachments.order(:position, :id).pluck(:position, :media_attachment_id)
    expect(reordered).to eq [[0, ids[1]], [1, ids[0]]]
    expect(MediaAttachment.where(id: ids).count).to eq 2
  end

  it 'downloads one shared video once when two resources ask together' do
    other_user = Fabricate(:user)
    enable_external_bridge_rss!(other_user)
    other = external_project_for(other_user)
    revision = 'rev-shared-video'
    digest = ExternalBridge::RSS::MediaDigest.url_digest(video_url)
    [bundle, other].each do |item|
      item[:resource].update!(
        media_revision: revision,
        media_candidates: [
          { 'url' => video_url, 'kind' => 'video', 'mime_hint' => 'video/webm', 'length_hint' => webm.bytesize, 'position' => 0, 'description' => 'Clip' },
        ]
      )
    end
    stub_request(:get, video_url).to_return do
      sleep 0.3
      { status: 200, body: webm, headers: { 'Content-Type' => 'video/webm', 'Content-Length' => webm.bytesize.to_s } }
    end

    threads = [bundle, other].map do |item|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::RSS::Media::Fetch.new.call(item[:resource].id, revision, digest)
        end
        :ok
      rescue StandardError => e
        e
      end
    end

    expect(threads.map(&:value)).to all(eq(:ok))
    expect(a_request(:head, video_url)).to have_been_made.once
    expect(a_request(:get, video_url)).to have_been_made.once
    expect(ExternalMediaAsset.where(url_digest: digest, state: 'ready').count).to eq 1
    attached = [bundle, other].map { |item| item[:status].reload.media_attachments.count }
    expect(attached).to eq [1, 1]
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
