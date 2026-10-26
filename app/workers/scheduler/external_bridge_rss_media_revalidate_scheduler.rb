# frozen_string_literal: true

# Enqueues conditional GETs for ready images whose validation is older than
# the interval. One pass is at most MEDIA_REVALIDATE_BATCH assets, and only
# assets a refresh has already linked to a resource. It does not scan every
# resource and it does not run when the RSS flag is off.
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
                      .order(Arel.sql('validated_at ASC NULLS FIRST'), :id)
                      .limit(ExternalBridge::RSS::Limits::MEDIA_REVALIDATE_BATCH)
  end
end
