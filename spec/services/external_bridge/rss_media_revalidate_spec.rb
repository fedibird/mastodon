# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS image revalidation' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/revalidate.xml' }
  let(:image_url) { 'https://cdn.example/story.png' }
  let(:second_url) { 'https://cdn.example/other.png' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }
  let(:jpeg) { Rails.root.join('spec', 'fixtures', 'files', 'attachment.jpg').binread }

  before do
    enable_external_bridge_rss!(user)
    redis.del('external_bridge:rss_media:host:cdn.example')
    stub_request(:get, image_url).to_return(status: 200, body: png, headers: image_headers('v1'))
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
  end

  it 'stores validators and does not GET a fresh image again on the next refresh' do
    asset = ExternalMediaAsset.find_by!(kind: 'image')
    expect(asset.validator_etag).to eq '"v1"'
    expect(asset.validator_last_modified).to eq 'Mon, 01 Jan 2024 00:00:00 GMT'
    expect(asset.validated_at).to be_present
    expect(asset.generation).to eq 1
    expect(ExternalMediaAssetResource.where(external_media_asset_id: asset.id).count).to eq 1

    ExternalBridge::RSS::Media::Sync.enqueue!(ExternalResource.find_by!(title: 'Story'))

    expect(a_request(:get, image_url)).to have_been_made.once
  end

  it 'reuses the file on 304 and does not GET a second time' do
    age_asset!
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 304, body: '')

    resource = ExternalResource.find_by!(title: 'Story')
    digest = ExternalBridge::RSS::MediaDigest.url_digest(image_url)
    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, digest)).to eq :not_modified
    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, digest)).to eq :fresh

    asset = ExternalMediaAsset.find_by!(url_digest: digest)
    expect(asset).to be_ready
    expect(asset.file_file_name).to be_present
    expect(asset.revalidate_attempt).to eq 0
    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.once
  end

  it 'does not leave a missing file ready after 304' do
    asset = age_asset!
    FileUtils.rm_f(asset.file.path)
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 304, body: '')

    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaFetchWorker.clear
      result = ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)

      expect(result).to eq :local_missing
      expect(asset.reload).not_to be_ready
      expect(asset.failure_code).to eq 'local_missing'
      expect(ExternalBridge::RSS::MediaFetchWorker.jobs.size).to eq 1
    end
    expect(Status.find(projection_status_id).media_attachments.count).to eq 1
  end

  it 'restores a missing file with an unconditional GET when 304 persists' do
    asset = age_asset!
    digest = asset.url_digest
    revision = ExternalResource.find(asset_resource_id).media_revision
    FileUtils.rm_f(asset.file.path)
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 304, body: '')

    fetch_args = nil
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaFetchWorker.clear
      expect(ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, digest)).to eq :local_missing
      expect(asset.reload).not_to be_ready
      expect(Scheduler::ExternalBridgeRSSMediaRevalidateScheduler.new.perform).to eq 0

      ExternalBridge::RSS::MediaFetchWorker.clear
      ExternalBridge::RSS::Media::Sync.enqueue!(ExternalResource.find(asset_resource_id))
      expect(ExternalBridge::RSS::MediaFetchWorker.jobs.size).to eq 1
      fetch_args = ExternalBridge::RSS::MediaFetchWorker.jobs.last['args']
    end
    expect(fetch_args).to eq [asset_resource_id, revision, digest]

    ExternalBridge::RSS::MediaFetchWorker.new.perform(*fetch_args)

    expect(a_request(:get, image_url)).to have_been_made.times(3)
    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.once
    asset.reload
    expect(asset).to be_ready
    expect(asset.failure_code).to be_nil
    expect(asset.file.exists?).to be true
    expect(asset.fingerprint).to eq Digest::SHA256.hexdigest(png)
    expect(Status.find(projection_status_id).media_attachments.count).to eq 1

    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    expect(ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, digest)).to eq :not_modified
    expect(asset.reload).to be_ready
    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.twice
  end

  it 'touches validators when a 200 body matches the stored fingerprint' do
    asset = age_asset!
    previous_generation = asset.generation
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 200, body: png, headers: image_headers('v2'))

    result = ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)

    expect(result).to eq :unchanged
    asset.reload
    expect(asset.generation).to eq previous_generation
    expect(asset.validator_etag).to eq '"v2"'
    expect(asset.fingerprint).to eq Digest::SHA256.hexdigest(png)
    expect(ExternalMediaAsset.where(kind: 'image').count).to eq 1
    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.once
  end

  it 'installs a new generation when the 200 body changes and releases the previous file' do
    asset = age_asset!
    old_asset_id = asset.id
    old_attachment_id = MediaAttachment.pick(:id)
    status = Status.find(projection_status_id)
    revision = ExternalResource.find(asset_resource_id).media_revision
    Rails.cache.write("statuses/#{status.id}", 'stale')
    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!)
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 200, body: jpeg, headers: image_headers('v3', 'image/jpeg'))

    result = ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)

    expect(result).to eq :replaced
    replacement = ExternalMediaAsset.find_by!(url_digest: asset.url_digest)
    expect(replacement.id).not_to eq old_asset_id
    expect(replacement.generation).to eq 2
    expect(replacement.fingerprint).to eq Digest::SHA256.hexdigest(jpeg)
    expect(replacement.validator_etag).to eq '"v3"'
    expect(ExternalMediaAsset.find_by(id: old_asset_id)).to be_nil
    expect(MediaAttachment.find_by(id: old_attachment_id)).to be_nil
    expect(status.reload.media_attachments.count).to eq 1
    attachment = status.media_attachments.first
    expect(attachment.file_content_type).to eq 'image/jpeg'
    expect(FastImage.type(attachment.file.path)).to eq :jpeg
    expect(ExternalResource.find(asset_resource_id).media_revision).to eq revision
    expect(Rails.cache.read("statuses/#{status.id}")).to be_nil
    expect(ExternalBridge::Streaming::Scheduler).to have_received(:bump_and_schedule_content!).with(kind_of(ExternalStatusProjection))
    expect(ExternalMediaGcIntent.where(target_id: old_asset_id, reason: 'generation_replaced', state: 'released')).to exist
  end

  it 'keeps the current file and backs off when the conditional GET times out' do
    asset = age_asset!
    stub_request(:get, image_url).with(headers: conditional_headers).to_timeout

    expect(ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)).to eq :failed

    asset.reload
    expect(asset).to be_ready
    expect(asset.file.exists?).to be true
    expect(asset.failure_code).to eq 'fetch_failed'
    expect(asset.revalidate_attempt).to eq 1
    expect(asset.revalidate_after).to be_within(5.seconds).of(15.seconds.from_now)
    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.once
  end

  it 'waits seven days after the third failure' do
    asset = age_asset!
    asset.update_columns(revalidate_attempt: 2, revalidate_after: 1.minute.ago)
    stub_request(:get, image_url).with(headers: conditional_headers).to_timeout

    ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)

    expect(asset.reload.revalidate_attempt).to eq 3
    expect(asset.revalidate_after).to be_within(1.minute).of(7.days.from_now)
    expect(asset).to be_ready
  end

  it 'enqueues at most the per-refresh budget' do
    stub_request(:get, second_url).to_return(status: 200, body: png, headers: image_headers('v1'))
    feed = ExternalBridge::RSS::Parser.parse!(rss_document(item_xml(second: true)))
    response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
    ExternalBridge::RSS::Ingest.new.apply_public!(ExternalSource.find_by!(canonical_key: feed_url), feed, response)
    ExternalMediaAsset.where(kind: 'image').update_all(validated_at: 25.hours.ago, revalidate_after: nil)

    resource = ExternalResource.find_by!(title: 'Story')
    stub_const('ExternalBridge::RSS::Limits::MEDIA_REVALIDATE_PER_REFRESH', 1)
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaRevalidateWorker.clear
      ExternalBridge::RSS::Media::Sync.enqueue!(resource)
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.size).to eq 1
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.first['args'].join(' ')).not_to include('http')
    end
  end

  it 'keeps a shared URL revalidating after the other feed resource is removed' do
    other_user = Fabricate(:user)
    enable_external_bridge_rss!(other_user)
    other_feed = 'https://feeds.example/revalidate-other.xml'
    stub_request(:get, other_feed).to_return(status: 200, body: rss_document(other_item_xml))
    ExternalBridge::RSS::Subscribe.new.call(user: other_user, url: other_feed)

    digest = ExternalBridge::RSS::MediaDigest.url_digest(image_url)
    asset = ExternalMediaAsset.find_by!(url_digest: digest)
    first = ExternalResource.find_by!(title: 'Story')
    second = ExternalResource.find_by!(title: 'Other story')
    expect(linked_resource_ids(asset)).to contain_exactly(first.id, second.id)

    stale = project_for(Fabricate(:user))
    ExternalBridge::RSS::Media::AssetResource.remember!(asset.id, stale[:resource].id)
    asset = age_asset!
    old_id = asset.id
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 200, body: jpeg, headers: image_headers('v3', 'image/jpeg'))

    expect(ExternalBridge::RSS::Media::Revalidate.call(first.id, digest)).to eq :replaced

    replacement = ExternalMediaAsset.find_by!(url_digest: digest)
    expect(replacement.id).not_to eq old_id
    expect(ExternalMediaAsset.find_by(id: old_id)).to be_nil
    expect(linked_resource_ids(replacement)).to contain_exactly(first.id, second.id)
    expect(ExternalMediaAssetResource.where(external_resource_id: stale[:resource].id)).to be_empty

    drop_resource!(first)
    expect(linked_resource_ids(replacement)).to eq [second.id]

    replacement.update_columns(validated_at: 25.hours.ago, revalidate_after: nil, revalidate_attempt: 0)
    stub_request(:get, image_url).with(headers: v3_headers).to_return(status: 304, body: '')
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaRevalidateWorker.clear
      expect(Scheduler::ExternalBridgeRSSMediaRevalidateScheduler.new.perform).to eq 1
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.last['args']).to eq [second.id, digest]
    end

    expect(ExternalBridge::RSS::Media::Revalidate.call(second.id, digest)).to eq :not_modified
    expect(replacement.reload).to be_ready
    expect(replacement.file.exists?).to be true
  end

  it 'repoints subscribers in batches and does not delete the old file early' do
    other = Fabricate(:user)
    enable_external_bridge_rss!(other)
    ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)
    expect(ExternalProjectionAttachment.count).to eq 2

    asset = age_asset!
    old_id = asset.id
    validated_at = asset.validated_at
    old_path = asset.file.path
    stub_const('ExternalBridge::RSS::Limits::MEDIA_REPOINT_BATCH', 1)
    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!)
    stub_request(:get, image_url).with(headers: conditional_headers).to_return(status: 200, body: jpeg, headers: image_headers('v3', 'image/jpeg'))

    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaGenerationContinueWorker.clear
      expect(ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)).to eq :partial
      expect(ExternalBridge::RSS::MediaGenerationContinueWorker.jobs.map { |job| job['args'] }).to eq [[asset_resource_id, asset.url_digest]]
    end

    expect(ExternalMediaAsset.find(old_id)).to be_ready
    expect(ExternalMediaAsset.find(old_id).validated_at).to be_within(1.second).of(validated_at)
    expect(File.exist?(old_path)).to be true
    incoming = ExternalMediaAsset.find_by!(url_digest: "incoming:#{old_id}")
    expect(incoming.generation).to eq 2
    expect(ExternalProjectionAttachment.where(external_media_asset_id: old_id).count).to eq 1
    expect(ExternalProjectionAttachment.where(external_media_asset_id: incoming.id).count).to eq 1
    expect(FastImage.type(ExternalProjectionAttachment.find_by!(external_media_asset_id: incoming.id).media_attachment.file.path)).to eq :jpeg
    expect(FastImage.type(ExternalProjectionAttachment.find_by!(external_media_asset_id: old_id).media_attachment.file.path)).to eq :png
    expect(ExternalMediaGcIntent.where(target_id: old_id, reason: 'generation_replaced')).to be_empty

    ExternalBridge::MediaGc.plan_generation!(old_id)
    ExternalBridge::MediaGc.release_ids!(attachment_ids: [], asset_ids: [old_id])
    expect(File.exist?(old_path)).to be true
    expect(ExternalMediaGcIntent.find_by!(target_id: old_id, reason: 'generation_replaced').last_error_code).to eq 'still_referenced'

    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaRevalidateWorker.clear
      expect(Scheduler::ExternalBridgeRSSMediaRevalidateScheduler.new.perform).to eq 1
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.last['args']).to eq [asset_resource_id, asset.url_digest]
      expect(ExternalBridge::RSS::Media::Revalidate.call(asset_resource_id, asset.url_digest)).to eq :replaced
    end

    expect(a_request(:get, image_url).with(headers: conditional_headers)).to have_been_made.once
    expect(ExternalMediaAsset.find_by(id: old_id)).to be_nil
    expect(File.exist?(old_path)).to be false
    survivor = ExternalMediaAsset.find(incoming.id)
    expect(survivor.url_digest).to eq asset.url_digest
    expect(survivor.generation).to eq 2
    expect(ExternalProjectionAttachment.where(external_media_asset_id: survivor.id).count).to eq 2
    [user, other].each do |subscriber|
      status = Status.find(ExternalStatusProjection.find_by!(user_id: subscriber.id).status_id)
      expect(FastImage.type(status.media_attachments.first.file.path)).to eq :jpeg
    end
  end

  it 'does not let unlinked assets fill the scheduler batch' do
    asset = age_asset!
    now = Time.current
    ExternalMediaAsset.insert_all!(Array.new(10) { |index| unlinked_row(index, now) })

    scheduler = Scheduler::ExternalBridgeRSSMediaRevalidateScheduler.new
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaRevalidateWorker.clear
      expect(scheduler.perform).to eq 1
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.last['args']).to eq [asset_resource_id, asset.url_digest]
    end
  end

  it 'does not queue revalidation while the flag is off or the asset has no resource link' do
    asset = age_asset!
    scheduler = Scheduler::ExternalBridgeRSSMediaRevalidateScheduler.new
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaRevalidateWorker.clear
      Setting.external_bridge_rss = false
      expect(scheduler.perform).to eq 0

      Setting.external_bridge_rss = true
      ExternalMediaAssetResource.delete_all
      expect(scheduler.perform).to eq 0

      ExternalBridge::RSS::Media::AssetResource.remember!(asset.id, asset_resource_id)
      expect(scheduler.perform).to eq 1
      expect(ExternalBridge::RSS::MediaRevalidateWorker.jobs.last['args']).to eq [asset_resource_id, asset.url_digest]
    end
  end

  def other_item_xml
    <<~XML
      <item>
        <guid>other-story</guid>
        <title>Other story</title>
        <link>https://example.com/other-story</link>
        <description><![CDATA[Other story<img src="#{image_url}" alt="Other">]]></description>
      </item>
    XML
  end

  def item_xml(second: false)
    extra = second ? %(<img src="#{second_url}" alt="Other">) : ''
    <<~XML
      <item>
        <guid>story</guid>
        <title>Story</title>
        <link>https://example.com/story</link>
        <description><![CDATA[Plain story<img src="#{image_url}" alt="Story">#{extra}]]></description>
      </item>
    XML
  end

  def image_headers(etag, type = 'image/png')
    { 'Content-Type' => type, 'ETag' => %("#{etag.delete('"')}"), 'Last-Modified' => 'Mon, 01 Jan 2024 00:00:00 GMT' }
  end

  def conditional_headers
    { 'If-None-Match' => '"v1"', 'If-Modified-Since' => 'Mon, 01 Jan 2024 00:00:00 GMT' }
  end

  def v3_headers
    { 'If-None-Match' => '"v3"', 'If-Modified-Since' => 'Mon, 01 Jan 2024 00:00:00 GMT' }
  end

  def linked_resource_ids(asset)
    ExternalMediaAssetResource.where(external_media_asset_id: asset.id).order(:id).pluck(:external_resource_id)
  end

  def drop_resource!(resource)
    status_ids = ExternalStatusProjection.where(external_resource_id: resource.id).pluck(:status_id)
    status_ids.each { |status_id| ExternalBridge::ProjectionPurge.purge_status!(Status.find(status_id)) }
    ExternalProjectionSuppression.where(external_resource_id: resource.id).delete_all
    ExternalProjectionFailure.where(external_resource_id: resource.id).delete_all
    resource.destroy!
  end

  def unlinked_row(index, now)
    {
      url_digest: "unlinked-#{index}",
      kind: 'image',
      state: 'ready',
      generation: 1,
      attempt_count: 0,
      revalidate_attempt: 0,
      validated_at: nil,
      created_at: now,
      updated_at: now,
    }
  end

  def age_asset!
    asset = ExternalMediaAsset.find_by!(kind: 'image')
    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil, revalidate_attempt: 0)
    asset
  end

  def asset_resource_id
    ExternalResource.find_by!(title: 'Story').id
  end

  def projection_status_id
    ExternalStatusProjection.find_by!(user_id: user.id).status_id
  end
end
