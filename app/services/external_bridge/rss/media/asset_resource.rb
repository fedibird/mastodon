# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Records that a resource still lists an asset's digest. The URL is not
      # copied here. Inserts are idempotent and never raise into a refresh.
      class AssetResource
        def self.remember!(asset_id, resource_id)
          link!(asset_id, resource_id)
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] media asset link skipped error=#{e.class}")
          false
        end

        # Raises into the caller. Generation retirement runs inside a
        # transaction, and a swallowed PostgreSQL error would abort it.
        def self.link!(asset_id, resource_id)
          asset_key = asset_id.to_i
          resource_key = resource_id.to_i
          return false if asset_key.zero? || resource_key.zero?
          return false unless ExternalResource.exists?(id: resource_key)

          now = Time.current
          quoted = ExternalMediaAssetResource.connection.quote(now)
          ExternalMediaAssetResource.connection.execute(<<~SQL.squish)
            INSERT INTO external_media_asset_resources
              (external_media_asset_id, external_resource_id, created_at, updated_at)
            VALUES
              (#{asset_key}, #{resource_key}, #{quoted}, #{quoted})
            ON CONFLICT (external_media_asset_id, external_resource_id) DO NOTHING
          SQL
          true
        end
      end
    end
  end
end
