# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Records that a resource still lists an asset's digest. The URL is not
      # copied here. Inserts are idempotent and never raise into a refresh.
      class AssetResource
        def self.remember!(asset_id, resource_id)
          return if asset_id.blank? || resource_id.blank?

          now = Time.current
          ExternalMediaAssetResource.connection.execute(<<~SQL.squish)
            INSERT INTO external_media_asset_resources
              (external_media_asset_id, external_resource_id, created_at, updated_at)
            VALUES
              (#{asset_id.to_i}, #{resource_id.to_i}, #{ExternalMediaAssetResource.connection.quote(now)}, #{ExternalMediaAssetResource.connection.quote(now)})
            ON CONFLICT (external_media_asset_id, external_resource_id) DO NOTHING
          SQL
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] media asset link skipped error=#{e.class}")
        end
      end
    end
  end
end
