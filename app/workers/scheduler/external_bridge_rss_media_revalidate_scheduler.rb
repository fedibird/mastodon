# frozen_string_literal: true

# Enqueues conditional GETs for ready images whose validation is older than
# the interval. The link filter is applied before LIMIT, so unlinked rows
# cannot fill the batch. One pass is at most MEDIA_REVALIDATE_BATCH assets.
# It does not scan every resource and it does not run when the RSS flag is off.
class Scheduler::ExternalBridgeRSSMediaRevalidateScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  def perform
    return 0 unless ExternalBridge::Feature.enabled?

    queued = 0
    due_assets.each do |asset|
      resource_id = ExternalMediaAssetResource.where(external_media_asset_id: asset.id).order(:id).pick(:external_resource_id)
      next if resource_id.blank?

      ExternalBridge::RSS::MediaRevalidateWorker.perform_async(resource_id, asset.url_digest)
      queued += 1
    end
    Rails.logger.info("[Scheduler::ExternalBridgeRSSMediaRevalidateScheduler] queued=#{queued}")
    queued
  end

  private

  def due_assets
    now = Time.current
    cutoff = now - ExternalBridge::RSS::Limits::MEDIA_REVALIDATE_AFTER
    ExternalMediaAsset.ready.where(kind: 'image')
                      .where('revalidate_after IS NULL OR revalidate_after <= ?', now)
                      .where('validated_at IS NULL OR validated_at <= ?', cutoff)
                      .where(linked_asset_sql)
                      .order(Arel.sql('validated_at ASC NULLS FIRST'), :id)
                      .limit(ExternalBridge::RSS::Limits::MEDIA_REVALIDATE_BATCH)
  end

  # EXISTS runs as a filter. LIMIT is applied to that result, not to the
  # unlinked ready images that sort first when validated_at is null.
  def linked_asset_sql
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM external_media_asset_resources
        WHERE external_media_asset_resources.external_media_asset_id = external_media_assets.id
      )
    SQL
  end
end
