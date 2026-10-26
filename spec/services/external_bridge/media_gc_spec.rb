# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External media GC' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/media-gc.xml' }
  let(:image_url) { 'https://cdn.example/gc-story.png' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    enable_external_bridge_rss!(user, other)
    stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml), headers: { 'Content-Type' => 'application/rss+xml' })
  end

  def item_xml
    <<~XML
      <item>
        <guid>gc-story</guid>
        <title>GC Story</title>
        <link>https://example.com/gc-story</link>
        <description><![CDATA[Plain story<img src="#{image_url}" alt="Story">]]></description>
      </item>
    XML
  end

  def subscribe!(subscriber)
    ExternalBridge::RSS::Subscribe.new.call(user: subscriber, url: feed_url)
  end

  def projection_status(subscriber)
    Status.find(ExternalStatusProjection.find_by!(user_id: subscriber.id).status_id)
  end

  def compose_upload(owner)
    attachment = nil
    Tempfile.create(['compose', '.png']) do |file|
      file.binmode
      file.write(png)
      file.rewind
      attachment = MediaAttachment.create!(account: owner.account, file: file, description: 'draft')
    end
    attachment
  end

  it 'releases a purged projection file and leaves a compose upload in place' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    upload = compose_upload(user)
    upload_path = upload.file.path
    expect(File.exist?(path)).to be true

    ExternalBridge::ProjectionPurge.purge_status!(status)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(ExternalMediaAsset.count).to eq 0
    expect(File.exist?(path)).to be false
    expect(upload.reload).to be_persisted
    expect(File.exist?(upload_path)).to be true
    expect(ExternalMediaGcIntent.pending).to be_empty
    expect(ExternalMediaGcIntent.where(target_id: upload.id)).to be_empty
  end

  it 'keeps blobs and writes no plan when the purge transaction rolls back' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    asset_id = ExternalMediaAsset.pick(:id)

    ActiveRecord::Base.transaction do
      ExternalBridge::ProjectionPurge.purge_status!(status)
      raise ActiveRecord::Rollback
    end

    expect(Status.unscoped.exists?(status.id)).to be true
    expect(attachment.reload).to be_persisted
    expect(attachment.status_id).to eq status.id
    expect(ExternalMediaAsset.exists?(asset_id)).to be true
    expect(ExternalMediaGcIntent.count).to eq 0
    expect(File.exist?(path)).to be true
  end

  it 'recovers files when the process dies after the delete commits' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    upload = compose_upload(user)
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)

    ExternalBridge::ProjectionPurge.purge_status!(status)

    expect(Status.unscoped.exists?(status.id)).to be false
    expect(attachment.reload).to be_persisted
    expect(attachment.status_id).to be_nil
    expect(File.exist?(path)).to be true
    expect(ExternalMediaGcIntent.pending.count).to eq 2

    report = ExternalBridge::MediaGc.diagnose
    expect(report[:pending]).to eq 2
    expect(report[:samples].map { |row| row[:decision] }).to all(eq('release'))
    expect(File.exist?(path)).to be true

    ExternalBridge::MediaGc.drain!(respect_grace: false)
    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(ExternalMediaAsset.count).to eq 0
    expect(File.exist?(path)).to be false
    expect(upload.reload).to be_persisted
    expect(ExternalMediaGcIntent.pending).to be_empty
  end

  it 'does not plan or drain a compose upload, even an old one' do
    upload = compose_upload(user)
    upload.update_columns(created_at: 10.days.ago)
    ExternalBridge::MediaGc.plan_purge!({ attachment_ids: [upload.id], asset_ids: [] })

    expect(ExternalMediaGcIntent.count).to eq 0
    ExternalBridge::MediaGc.drain!(respect_grace: false)
    expect(upload.reload).to be_persisted
    expect(File.exist?(upload.file.path)).to be true
  end

  it 'retains a forged purge intent that has no bound proof' do
    upload = compose_upload(user)
    intent = ExternalMediaGcIntent.create!(
      target_type: 'media_attachment',
      target_id: upload.id,
      reason: 'projection_purge',
      state: 'pending',
      owner_account_id: user.account_id,
      captured_status_id: 10,
      source_attachment_id: 10,
      captured_projection_id: 10,
      available_at: Time.current
    )

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(upload.reload).to be_persisted
    expect(File.exist?(upload.file.path)).to be true
    expect(intent.reload.state).to eq 'retained'
    expect(intent.last_error_code).to eq 'unproven'
  end

  it 'refuses a proof that does not name a live projection attachment' do
    expect do
      ExternalMediaGcProof.create!(
        source_attachment_id: 9_000_000_000,
        media_attachment_id: 1,
        external_status_projection_id: 1,
        account_id: 1,
        status_id: 1
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /live projection attachment/)
  end

  it 'binds a proof to the live link and will not retarget it at a compose upload' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    link = ExternalProjectionAttachment.find_by!(media_attachment_id: attachment.id)
    upload = compose_upload(user)

    proof = ExternalMediaGcProof.create!(
      source_attachment_id: link.id,
      media_attachment_id: upload.id,
      external_status_projection_id: 1,
      account_id: other.account_id,
      status_id: 1
    )

    expect(proof.reload.media_attachment_id).to eq attachment.id
    expect(proof.external_status_projection_id).to eq link.external_status_projection_id
    expect(proof.account_id).to eq user.account_id
    expect(proof.status_id).to eq status.id
    expect do
      proof.update!(media_attachment_id: upload.id)
    end.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect(upload.reload).to be_persisted
  end

  it 'does not release a compose upload when a purged proof is copied onto it' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    upload = compose_upload(user)
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)
    ExternalBridge::ProjectionPurge.purge_status!(status)
    proof = ExternalMediaGcProof.find_by!(media_attachment_id: attachment.id)

    forged = ExternalMediaGcIntent.create!(
      target_type: 'media_attachment',
      target_id: upload.id,
      reason: 'projection_purge',
      state: 'pending',
      owner_account_id: proof.account_id,
      captured_status_id: proof.status_id,
      source_attachment_id: proof.source_attachment_id,
      captured_projection_id: proof.external_status_projection_id,
      available_at: Time.current
    )

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(upload.reload).to be_persisted
    expect(File.exist?(upload.file.path)).to be true
    expect(forged.reload.state).to eq 'retained'
    expect(forged.last_error_code).to eq 'unproven'
    expect(MediaAttachment.where(id: attachment.id)).to be_empty
  end

  it 'retains a purged attachment when the intent projection id does not match the proof' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)
    ExternalBridge::ProjectionPurge.purge_status!(status)
    intent = ExternalMediaGcIntent.find_by!(target_type: 'media_attachment', target_id: attachment.id)
    intent.update_columns(captured_projection_id: intent.captured_projection_id + 1)

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(attachment.reload).to be_persisted
    expect(File.exist?(path)).to be true
    expect(intent.reload.state).to eq 'retained'
    expect(intent.last_error_code).to eq 'unproven'
  end

  it 'rejects an attachment intent whose projection id was omitted' do
    upload = compose_upload(user)

    expect do
      ExternalMediaGcIntent.create!(
        target_type: 'media_attachment',
        target_id: upload.id,
        reason: 'projection_purge',
        state: 'pending',
        owner_account_id: user.account_id,
        captured_status_id: 10,
        source_attachment_id: 10,
        available_at: Time.current
      )
    end.to raise_error(ActiveRecord::StatementInvalid)

    expect(upload.reload).to be_persisted
  end

  it 'keeps the shared asset while another subscriber still uses it' do
    subscribe!(user)
    subscribe!(other)
    status = projection_status(user)
    own = status.media_attachments.first
    other_attachment = projection_status(other).media_attachments.first
    asset_id = ExternalMediaAsset.pick(:id)

    ExternalBridge::ProjectionPurge.purge_status!(status)

    expect(MediaAttachment.where(id: own.id)).to be_empty
    expect(other_attachment.reload).to be_persisted
    expect(ExternalMediaAsset.exists?(asset_id)).to be true
    retained = ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset', target_id: asset_id)
    expect(retained.state).to eq 'retained'
    expect(retained.last_error_code).to eq 'still_referenced'
  end

  it 'keeps the asset when a new projection appears before recovery' do
    subscribe!(user)
    status = projection_status(user)
    old_attachment_id = status.media_attachments.first.id
    subscription = ExternalSubscription.find_by!(user_id: user.id)
    resource = ExternalResource.find_by!(title: 'GC Story')
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)
    ExternalBridge::ProjectionPurge.purge_ids_in_transaction!([status.id])

    result = ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: [resource])
    expect(result.succeeded).to eq 1
    fresh = projection_status(user)
    expect(fresh.media_attachments.map(&:id)).not_to include(old_attachment_id)

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: old_attachment_id)).to be_empty
    expect(fresh.reload.media_attachments).not_to be_empty
    expect(ExternalMediaAsset.count).to eq 1
    expect(ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset').state).to eq 'retained'
  end

  it 'retries a storage error and then releases the same intent' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    allow_any_instance_of(MediaAttachment).to receive(:destroy!).and_raise(Paperclip::Error)

    ExternalBridge::ProjectionPurge.purge_status!(status)

    intent = ExternalMediaGcIntent.find_by!(target_type: 'media_attachment', target_id: attachment.id)
    expect(intent.state).to eq 'pending'
    expect(intent.last_error_code).to eq 'storage_error'
    expect(intent.attempt_count).to eq 1
    expect(File.exist?(path)).to be true

    allow_any_instance_of(MediaAttachment).to receive(:destroy!).and_call_original
    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(File.exist?(path)).to be false
    expect(intent.reload.state).to eq 'released'
  end

  it 'does not steal a live lease, and releases the row once the lease expires' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)
    ExternalBridge::ProjectionPurge.purge_status!(status)
    intent = ExternalMediaGcIntent.find_by!(target_type: 'media_attachment', target_id: attachment.id)
    intent.update_columns(lease_token: 'held', leased_until: 5.minutes.from_now, attempt_count: 1)

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(intent.reload.lease_token).to eq 'held'
    expect(attachment.reload).to be_persisted
    intent.update_columns(leased_until: 1.minute.ago)
    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
  end

  it 'releases an unreferenced generation and retains a referenced one' do
    subscribe!(user)
    asset = ExternalMediaAsset.first
    ExternalBridge::MediaGc.plan_generation!(asset.id)
    ExternalBridge::MediaGc.drain!(respect_grace: false)
    expect(asset.reload).to be_persisted
    expect(ExternalMediaGcIntent.find_by!(reason: 'generation_replaced').state).to eq 'retained'

    ExternalProjectionAttachment.delete_all
    ExternalBridge::MediaGc.plan_generation!(asset.id)
    ExternalBridge::MediaGc.drain!(respect_grace: false)
    expect(ExternalMediaAsset.where(id: asset.id)).to be_empty
    expect(projection_status(user).media_attachments).not_to be_empty
  end

  it 'releases a replaced attachment when the projection is purged before that intent runs' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    upload = compose_upload(user)
    resource = ExternalResource.find_by!(title: 'GC Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    resource.update!(media_candidates: [], media_revision: 'cleared')
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)

    ExternalBridge::RSS::Media::Sync.attach_ready!(marker, resource)

    expect(attachment.reload).to be_persisted
    expect(attachment.status_id).to eq status.id
    expect(File.exist?(path)).to be true
    replaced = ExternalMediaGcIntent.find_by!(target_type: 'media_attachment', target_id: attachment.id, reason: 'attachment_replaced')
    expect(replaced.state).to eq 'pending'
    expect(replaced.captured_projection_id).to eq marker.id
    expect(ExternalMediaGcProof.find_by!(source_attachment_id: replaced.source_attachment_id).media_attachment_id).to eq attachment.id

    ExternalBridge::ProjectionPurge.purge_status!(status)

    expect(Status.unscoped.exists?(status.id)).to be false
    expect(attachment.reload.status_id).to be_nil
    expect(ExternalProjectionAttachment.where(media_attachment_id: attachment.id)).to be_empty
    expect(ExternalMediaGcIntent.pending.where(target_type: 'media_attachment', target_id: attachment.id).count).to eq 1

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(File.exist?(path)).to be false
    expect(replaced.reload.state).to eq 'released'
    expect(upload.reload).to be_persisted
    expect(File.exist?(upload.file.path)).to be true
    expect(ExternalMediaAsset.count).to eq 0
  end

  it 'releases a shared asset from the recheck written when the second plan lost the pending insert' do
    subscribe!(user)
    subscribe!(other)
    asset_id = ExternalMediaAsset.pick(:id)
    own_ids = projection_status(user).media_attachments.pluck(:id)
    other_ids = projection_status(other).media_attachments.pluck(:id)
    media = { attachment_ids: own_ids + other_ids, asset_ids: [asset_id] }

    ExternalBridge::MediaGc.plan_purge!(media)
    ExternalBridge::MediaGc.plan_purge!(media)

    expect(ExternalMediaGcIntent.pending.where(target_type: 'external_media_asset', target_id: asset_id).count).to eq 1
    expect(ExternalMediaGcAssetRecheck.pending.where(external_media_asset_id: asset_id).count).to eq 2
    first = ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset', target_id: asset_id)
    first.update!(state: 'retained', last_error_code: 'still_referenced', resolved_at: Time.current)
    ExternalProjectionAttachment.where(external_media_asset_id: asset_id).delete_all

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(ExternalMediaAsset.where(id: asset_id)).to be_empty
    successor = ExternalMediaGcIntent.where(target_type: 'external_media_asset', target_id: asset_id).order(:id).last
    expect(successor.id).to be > first.id
    expect(successor.state).to eq 'released'
    expect(MediaAttachment.where(id: own_ids + other_ids)).not_to be_empty
  end

  it 'releases a replaced projection attachment through the sync transaction' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    path = attachment.file.path
    upload = compose_upload(user)
    resource = ExternalResource.find_by!(title: 'GC Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    resource.update!(media_candidates: [], media_revision: 'cleared')

    ExternalBridge::RSS::Media::Sync.attach_ready!(marker, resource)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(File.exist?(path)).to be false
    expect(ExternalMediaAsset.count).to eq 0
    expect(upload.reload).to be_persisted
    expect(status.reload.media_attachments).to be_empty
  end

  it 'finishes unsubscribe media after the commit hook did not run' do
    subscribe!(user)
    status = projection_status(user)
    attachment = status.media_attachments.first
    upload = compose_upload(user)
    subscription_id = ExternalStatusProjection.find_by!(user_id: user.id).external_subscription_id
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)

    ExternalBridge::RSS::Unsubscribe.new.call(user: user, subscription_id: subscription_id)

    expect(Status.unscoped.exists?(status.id)).to be false
    expect(attachment.reload).to be_persisted
    expect(upload.reload).to be_persisted
    expect(ExternalMediaGcIntent.pending.where.not(external_subscription_deletion_id: nil)).not_to be_empty

    ExternalBridge::MediaGc.drain!(respect_grace: false)

    expect(MediaAttachment.where(id: attachment.id)).to be_empty
    expect(upload.reload).to be_persisted
    expect(ExternalMediaAsset.count).to eq 0
  end

  it 'asks the worker to drain with no status ids once the grace has passed' do
    subscribe!(user)
    status = projection_status(user)
    path = status.media_attachments.first.file.path
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!)
    ExternalBridge::ProjectionPurge.purge_status!(status)
    expect(ExternalBridge::RSS::MediaGcWorker.instance_method(:perform).arity).to eq 0
    expect(File.exist?(path)).to be true

    travel 2.minutes do
      expect(Scheduler::ExternalBridgeRSSMediaGcScheduler.new.perform).to be_positive
    end

    expect(File.exist?(path)).to be false
    expect(ExternalMediaGcIntent.pending).to be_empty
  end
end
