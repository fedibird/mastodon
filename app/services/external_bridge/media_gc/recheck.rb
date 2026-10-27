# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Turns committed asset rechecks into a release attempt. A recheck whose
    # asset is still linked is closed: the subscriber who still holds it will
    # write another recheck when they drop it. A recheck whose asset is
    # unlinked inserts a pending intent when the previous one has already
    # left `pending`, then releases that intent.
    class Recheck
      def self.settle!(asset_ids)
        ids = MediaGc.normalize_ids(asset_ids)
        return { settled: 0, more: false } if ids.empty?

        rows = ExternalMediaGcAssetRecheck.pending.where(external_media_asset_id: ids).order(:id).to_a
        rows.each { |row| settle_row!(row) }
        { settled: rows.size, more: false }
      end

      def self.drain!(limit:, respect_grace:)
        scope = ExternalMediaGcAssetRecheck.pending
        scope = scope.where('available_at <= ?', Time.current) if respect_grace
        ids = scope.order(:id).limit(limit.to_i + 1).pluck(:id)
        more = ids.size > limit
        ids.first(limit.to_i).each do |id|
          row = ExternalMediaGcAssetRecheck.find_by(id: id, state: 'pending')
          settle_row!(row) if row
        end
        { settled: [ids.size, limit.to_i].min, more: more }
      end

      def self.settle_row!(row)
        asset_id = row.external_media_asset_id
        unless ExternalMediaAsset.exists?(id: asset_id)
          finish!(row, 'missing')
          return
        end
        if ExternalProjectionAttachment.exists?(external_media_asset_id: asset_id)
          finish!(row, 'still_referenced')
          return
        end

        Plan.ensure_asset!(asset_id, reason: row.reason, deletion_id: row.external_subscription_deletion_id)
        finish!(row, nil)
        MediaGc.release_ids!(attachment_ids: [], asset_ids: [asset_id])
      end

      def self.finish!(row, code)
        now = Time.current
        ExternalMediaGcAssetRecheck.where(id: row.id, state: 'pending').update_all(
          state: 'done',
          last_error_code: code,
          resolved_at: now,
          updated_at: now
        )
        Rails.logger.info("[ExternalBridge::MediaGc] action=recheck asset_id=#{row.external_media_asset_id} error=#{code}")
      end
    end
  end
end
