# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::MediaAttachmentCensus do
  include StatusesHelper

  let(:owner) { Fabricate(:user) }
  let(:large_url) { 'https://cdn.example/thumbs/large.jpg' }
  let(:small_url) { 'https://cdn.example/thumbs/small.jpg' }
  let(:article_url) { 'https://watch.example.com/watch?id=abc123' }
  let(:player_url) { 'https://player.example.com/embed/abc123' }

  def item_document
    Nokogiri::XML(<<~XML)
      <item>
        <thumb>#{small_url}</thumb>
        <thumb_large>#{large_url}</thumb_large>
        <embed><![CDATA[<iframe src="#{player_url}"></iframe>]]></embed>
      </item>
    XML
  end

  def scanned_candidates
    scan = ExternalBridge::RSS::EmbedScan.new
    item_document.root.element_children.each_with_index { |child, index| scan.observe(child, index) }
    raw = []
    hidden = []
    scan.apply!(raw, hidden, article_url)
    [raw, hidden]
  end

  def insert_image!(status)
    now = Time.current
    id = MediaAttachment.insert(
      {
        account_id: status.account_id,
        status_id: status.id,
        remote_url: '',
        file_file_name: 'pixel.jpg',
        file_content_type: 'image/jpeg',
        file_file_size: 8,
        type: 0,
        created_at: now,
        updated_at: now,
      },
      returning: %w(id)
    ).rows.first.first.to_i
    MediaAttachment.find(id)
  end

  it 'turns a large thumb, a small thumb, and an embed into one poster candidate' do
    raw, hidden = scanned_candidates
    poster = raw.find { |row| row['role'] == 'poster' }
    player = raw.find { |row| row['role'] == 'player' }
    resource = ExternalResource.new(media_candidates: raw)
    saved = ExternalBridge::RSS::Media::Sync.new(nil, resource).send(:saved_candidates)

    expect(raw.map { |row| row['role'] }).to eq %w(poster player)
    expect(poster['kind']).to eq 'image'
    expect(poster['url']).to eq large_url
    expect(poster['fallbacks']).to eq [small_url]
    expect(player['kind']).to eq 'embed'
    expect(player['url']).to eq player_url
    expect(hidden).to include(large_url, small_url)
    expect(saved.map { |row| row['role'] }).to eq ['poster']
    expect(saved.size).to eq 1
  end

  it 'keeps at most one ready poster and the attachment cap from desired files' do
    expect(Setting.attachments_max).to eq 4
    asset = ExternalMediaAsset.new(url_digest: 'digest', kind: 'image', state: 'ready')
    candidates = [
      { 'url' => 'https://cdn.example/gallery/1.jpg', 'kind' => 'image', 'role' => 'attachment' },
      { 'url' => 'https://cdn.example/gallery/2.jpg', 'kind' => 'image', 'role' => 'attachment' },
      { 'url' => 'https://cdn.example/gallery/3.jpg', 'kind' => 'image', 'role' => 'attachment' },
      { 'url' => 'https://cdn.example/gallery/4.jpg', 'kind' => 'image', 'role' => 'attachment' },
      { 'url' => 'https://cdn.example/gallery/5.jpg', 'kind' => 'image', 'role' => 'attachment' },
      { 'url' => large_url, 'kind' => 'image', 'role' => 'poster', 'fallbacks' => [small_url] },
      { 'url' => 'https://cdn.example/thumbs/previous.jpg', 'kind' => 'image', 'role' => 'poster' },
    ]
    sync = ExternalBridge::RSS::Media::Sync.new(nil, nil)
    allow(sync).to receive(:saved_candidates).and_return(candidates)
    allow(sync).to receive(:asset_for).and_return(asset)

    desired = sync.send(:desired_files)

    expect(desired.size).to eq 5
    expect(desired.count { |candidate, _asset| candidate['role'] == 'poster' }).to eq 1
    expect(desired.last.first['url']).to eq large_url
  end

  it 'counts raw rows the summary sees while the display list and the link do not' do
    bundle = external_project_for(owner, body: 'Imported article')
    status = bundle[:status]
    poster = insert_image!(status)
    previous = insert_image!(status)
    replaced = insert_image!(status)
    repointed = insert_image!(status)
    2.times { insert_image!(status) }
    status.update_columns(ordered_media_attachment_ids: [poster.id])
    poster_asset = ExternalMediaAsset.create!(url_digest: SecureRandom.hex(32), kind: 'image', state: 'failed')
    previous_asset = ExternalMediaAsset.create!(url_digest: SecureRandom.hex(32), kind: 'image', state: 'failed')
    ExternalProjectionAttachment.create!(
      external_status_projection: bundle[:marker],
      external_media_asset: poster_asset,
      media_attachment: poster,
      position: 0,
      kind: 'poster'
    )
    ExternalProjectionAttachment.create!(
      external_status_projection: bundle[:marker],
      external_media_asset: previous_asset,
      media_attachment: previous,
      position: 1,
      kind: 'poster'
    )
    ExternalMediaGcIntent.create!(
      target_type: 'media_attachment',
      target_id: replaced.id,
      reason: 'attachment_replaced',
      state: 'pending',
      owner_account_id: owner.account_id,
      captured_status_id: status.id,
      source_attachment_id: replaced.id,
      captured_projection_id: bundle[:marker].id,
      available_at: Time.current
    )
    ExternalMediaRepointStage.create!(
      media_attachment: repointed,
      external_media_asset: previous_asset,
      external_status_projection: bundle[:marker],
      account_id: status.account_id,
      status_id: status.id,
      lease_until: 1.hour.from_now
    )
    before_ids = status.media_attachments.order(:id).pluck(:id)

    snapshot = described_class.call(status.reload)
    encoded = JSON.generate(snapshot)

    expect(before_ids.size).to eq 6
    expect(snapshot[:raw_attachment_ids]).to eq before_ids
    expect(snapshot[:display_attachment_ids]).to eq []
    expect(snapshot[:summary_counts]).to eq(image: 6, video: 0, audio: 0)
    expect(snapshot[:projection_attachments].map { |row| row[:kind] }).to eq %w(poster poster)
    expect(snapshot[:raw_not_displayed_ids]).to match_array(before_ids)
    expect(snapshot[:raw_without_projection_row_ids]).to include(replaced.id, repointed.id)
    expect(snapshot[:lifecycle]).to include(
      hash_including(
        media_attachment_id: replaced.id,
        gc_intents: [hash_including(state: 'pending', reason: 'attachment_replaced')]
      ),
      hash_including(
        media_attachment_id: repointed.id,
        repoint_stages: [hash_including(state: 'pending')]
      )
    )
    expect(encoded).not_to include('http')
    expect(encoded).not_to include('Imported article')
    expect(status.ordered_media_attachments).to eq []
    I18n.with_locale(:ja) do
      expect(media_summary(status.reload)).to include('6 枚の画像')
    end
    expect(Formatter.instance.format(status.reload)).not_to include('original-media-link')
    expect(status.media_attachments.order(:id).pluck(:id)).to eq before_ids
    expect(ExternalMediaGcIntent.where(target_id: replaced.id, state: 'pending')).to exist
    expect(ExternalMediaRepointStage.where(media_attachment_id: repointed.id, state: 'pending')).to exist
  end
end
