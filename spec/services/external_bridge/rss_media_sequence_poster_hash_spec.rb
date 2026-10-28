# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'External RSS sequence poster hashes' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:stranger) { Fabricate(:user) }
  let(:bundle) { external_project_for(user) }
  let(:poster_url) { 'https://images.example/poster.jpg' }
  let(:fallback_url) { 'https://images.example/poster-small.jpg' }
  let(:player_url) { 'https://player.example.com/embed/abc123' }
  let(:same_video) { 'https://cdn.example/same.mp4' }
  let(:other_video) { 'https://cdn.example/other.mp4' }
  let(:talk_url) { 'https://cdn.example/talk.mp3' }
  let(:thumb) { '3OcRJYB4d3hwiIeHeEh3eIhw' }
  let(:blur) { 'LEHV6nWB2yk8pyo0adR*.7kCMdnj' }
  let(:other_thumb) { 'YJqGPQw7sFlsl9l9h3eIeHiPd4h3iIAH' }

  before do
    enable_external_bridge_rss!(user, other, stranger)
    bundle[:resource].update!(canonical_url: 'https://watch.example.com/watch?id=abc123', media_candidates: named_candidates)
    attach_poster!(bundle, thumb, blur)
  end

  it 'copies hashes from the named poster and does not reuse them for a different video' do
    body = owner_json(user, bundle[:status])
    rows = body[:fedibird_external][:sequence]
    embed = rows.find { |row| row[:type] == 'embed' }
    matched = rows.find { |row| row[:url] == same_video }
    unmatched = rows.find { |row| row[:url] == other_video }
    audio = rows.find { |row| row[:type] == 'audio' }

    expect(embed).to include(poster_thumbhash: thumb, poster_blurhash: blur, url: player_url)
    expect(embed[:poster]).to be_present
    expect(embed[:poster]).not_to include('images.example')
    expect(matched).to include(poster_thumbhash: thumb, poster_blurhash: blur)
    expect(matched).not_to have_key(:poster)
    expect(audio).to include(poster_thumbhash: thumb, poster_blurhash: blur)
    expect(audio).not_to have_key(:poster)
    expect(unmatched.keys).not_to include(:poster, :poster_thumbhash, :poster_blurhash)
    expect(body[:media_attachments]).to eq []

    media = body[:fedibird_external][:media]
    expect(media.find { |row| row[:url] == same_video }).to include(poster_thumbhash: thumb)
    expect(media.find { |row| row[:url] == other_video }).not_to have_key(:poster_thumbhash)
    expect(media.map { |row| row[:type] }).not_to include('embed')
    expect(bundle[:resource].reload.media_candidates.to_json).not_to include(thumb)
    expect(bundle[:resource].media_candidates.to_json).not_to include('poster_thumbhash')
  end

  it 'omits hashes while the poster file or the hash is missing' do
    attachment = bundle[:status].media_attachments.first
    attachment.update_columns(thumbhash: nil, blurhash: '   ')
    bare = sequence_for(bundle[:marker]).find { |row| row[:type] == 'embed' }
    expect(bare[:poster]).to be_present
    expect(bare).not_to have_key(:poster_thumbhash)
    expect(bare).not_to have_key(:poster_blurhash)

    attachment.update_columns(thumbhash: 'https://cdn.example/secret.jpg', blurhash: 'x' * 101)
    rejected = sequence_for(bundle[:marker]).find { |row| row[:type] == 'embed' }
    expect(rejected).not_to have_key(:poster_thumbhash)
    expect(rejected).not_to have_key(:poster_blurhash)

    attachment.update_columns(file_file_name: nil, thumbhash: thumb, blurhash: blur)
    missing = sequence_for(bundle[:marker]).find { |row| row[:type] == 'embed' }
    expect(missing).not_to have_key(:poster)
    expect(missing).not_to have_key(:poster_thumbhash)

    bundle[:marker].external_projection_attachments.delete_all
    unsaved = sequence_for(bundle[:marker]).find { |row| row[:type] == 'embed' }
    expect(unsaved).not_to have_key(:poster)
    expect(unsaved).not_to have_key(:poster_blurhash)
    expect(sequence_for(bundle[:marker]).find { |row| row[:url] == same_video }).not_to have_key(:poster_thumbhash)
  end

  it 'uses one legacy embed poster and does not guess across videos' do
    legacy = [
      poster_candidate,
      { 'url' => player_url, 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'position' => 1 },
      { 'url' => other_video, 'kind' => 'video', 'role' => 'attachment', 'poster_url' => 'https://cdn.example/other.jpg', 'position' => 2 },
    ]
    bundle[:resource].update!(media_candidates: legacy)

    rows = sequence_for(bundle[:marker])
    expect(rows.find { |row| row[:type] == 'embed' }).to include(poster_thumbhash: thumb)
    expect(rows.find { |row| row[:url] == other_video }).not_to have_key(:poster_thumbhash)

    mismatched_candidates = [
      poster_candidate,
      { 'url' => player_url, 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'poster_url' => 'https://images.example/missing.jpg', 'position' => 1 },
      { 'url' => 'https://clips.example.com/embed/abc123', 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'position' => 2 },
    ]
    bundle[:resource].update!(media_candidates: mismatched_candidates)
    mismatched = sequence_for(bundle[:marker])
    expect(mismatched.find { |row| row[:url] == player_url }).not_to have_key(:poster)
    expect(mismatched.find { |row| row[:url] == player_url }).not_to have_key(:poster_thumbhash)
    expect(mismatched.none? { |row| row[:poster_thumbhash] == thumb }).to be true

    ambiguous = [
      poster_candidate,
      { 'url' => player_url, 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'position' => 1 },
      { 'url' => 'https://clips.example.com/embed/abc123', 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'position' => 2 },
    ]
    bundle[:resource].update!(media_candidates: ambiguous)
    expect(sequence_for(bundle[:marker]).none? { |row| row.key?(:poster_thumbhash) }).to be true
  end

  it 'keeps hashes on the owning projection and out of another subscriber, ActivityPub, and a public note' do
    other_status, other_marker = project_onto!(other, bundle[:resource])
    attach_poster!({ status: other_status, marker: other_marker }, other_thumb, 'LKO2:N%2R6of9.kCMdnj')

    expect(owner_json(other, other_status)[:fedibird_external][:sequence].find { |row| row[:type] == 'embed' }[:poster_thumbhash]).to eq other_thumb
    expect(owner_json(other, other_status).to_json).not_to include(thumb)
    expect(owner_json(user, bundle[:status]).to_json).not_to include(other_thumb)

    stranger_body = REST::StatusSerializer.new(bundle[:status], scope: stranger, scope_name: :current_user).serializable_hash.deep_symbolize_keys
    expect(stranger_body).not_to have_key(:fedibird_external)
    expect(stranger_body.to_json).not_to include(thumb)
    expect(stranger_body[:media_attachments]).to eq []

    expect { ActivityPub::NoteSerializer.new(bundle[:status]).type }.to raise_error(Status::UnreleasedActivityObject)

    note = Status.create!(
      account: user.account,
      text: "Safe Feed Title\nRSS\nhttps://watch.example.com/watch?id=abc123",
      visibility: :public,
      searchability: :public,
      local: true,
      external_projection: false
    )
    rest = REST::StatusSerializer.new(note, scope: stranger, scope_name: :current_user).serializable_hash
    activity = ActivityPub::NoteSerializer.new(note).serializable_hash
    expect(rest.to_json).not_to include(thumb)
    expect(rest.to_json).not_to include('poster_thumbhash')
    expect(activity.to_json).not_to include(thumb)
    expect(activity.to_json).not_to include('poster_blurhash')
    expect(note.media_attachments).to be_empty
  end

  def named_candidates
    [
      poster_candidate,
      { 'url' => player_url, 'kind' => 'embed', 'role' => 'player', 'origin' => 'rss_embed', 'poster_url' => poster_url, 'duration' => 61, 'position' => 1 },
      { 'url' => same_video, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/mp4', 'poster_url' => fallback_url, 'position' => 2 },
      { 'url' => other_video, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'video/mp4', 'poster_url' => 'https://cdn.example/other.jpg', 'position' => 3 },
      { 'url' => talk_url, 'kind' => 'audio', 'role' => 'attachment', 'origin' => 'enclosure', 'mime_hint' => 'audio/mpeg', 'poster_url' => poster_url, 'position' => 4 },
    ]
  end

  def poster_candidate
    { 'url' => poster_url, 'kind' => 'image', 'role' => 'poster', 'origin' => 'rss_thumb', 'fallbacks' => [fallback_url], 'position' => 0 }
  end

  def attach_poster!(world, thumbhash, blurhash)
    digest = ExternalBridge::RSS::MediaDigest.url_digest(poster_url)
    asset = ExternalMediaAsset.find_by(url_digest: digest) || ExternalMediaAsset.create!(
      url_digest: digest,
      kind: 'image',
      state: 'failed'
    )
    attachment = MediaAttachment.create!(
      account: world[:status].account,
      status: world[:status],
      file: attachment_fixture('attachment.jpg'),
      remote_url: ''
    )
    attachment.update_columns(thumbhash: thumbhash, blurhash: blurhash)
    ExternalProjectionAttachment.create!(
      external_status_projection: world[:marker],
      external_media_asset: asset,
      media_attachment: attachment,
      position: 0,
      kind: 'poster'
    )
  end

  def project_onto!(owner, resource)
    subscription = ExternalSubscription.create!(user: owner, external_source: resource.external_source, state: 'active')
    status = Status.create!(
      account: owner.account,
      text: 'External only article',
      visibility: :external,
      searchability: :personal,
      uri: nil,
      external_projection: true,
      local: true,
      reply: false,
      sensitive: false
    )
    marker = ExternalStatusProjection.create!(
      user_id: owner.id,
      account_id: owner.account_id,
      external_source_id: resource.external_source_id,
      external_subscription_id: subscription.id,
      external_resource_id: resource.id,
      status_id: status.id,
      last_seen_revision: resource.revision
    )
    [status, marker]
  end

  def sequence_for(marker)
    ExternalBridge::RSS::Media::Sequence.for(marker.reload)
  end

  def owner_json(owner, status)
    REST::StatusSerializer.new(status.reload, scope: owner, scope_name: :current_user).serializable_hash.deep_symbolize_keys
  end
end
# rubocop:enable Metrics/BlockLength
