# frozen_string_literal: true

# Conditional revalidation for shared RSS images (issue #588, P3-A).
#
# Nullable validator columns and constant defaults only. PostgreSQL 11+ does
# not rewrite existing external_media_assets rows for those defaults. No URL
# backfill: a row is revalidated only after a refresh has recorded which
# resource still publishes its digest.
class AddExternalMediaRevalidation < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      add_column :external_media_assets, :validator_etag, :text
      add_column :external_media_assets, :validator_last_modified, :text
      add_column :external_media_assets, :validated_at, :datetime
      add_column :external_media_assets, :revalidate_after, :datetime
      add_column :external_media_assets, :revalidate_attempt, :integer, null: false, default: 0
      add_column :external_media_assets, :generation, :integer, null: false, default: 1

      execute <<~SQL
        ALTER TABLE external_media_assets
        ADD CONSTRAINT external_media_assets_generation_check
        CHECK (generation >= 1)
      SQL
      execute <<~SQL
        ALTER TABLE external_media_assets
        ADD CONSTRAINT external_media_assets_revalidate_attempt_check
        CHECK (revalidate_attempt >= 0)
      SQL

      execute <<~SQL
        CREATE INDEX index_ext_media_assets_on_image_revalidate
        ON external_media_assets (validated_at ASC NULLS FIRST, id)
        WHERE state = 'ready' AND kind = 'image'
      SQL

      create_table :external_media_asset_resources do |t|
        t.bigint :external_media_asset_id, null: false
        t.bigint :external_resource_id, null: false
        t.timestamps
      end
      add_index :external_media_asset_resources,
                [:external_media_asset_id, :external_resource_id],
                unique: true,
                name: 'index_ext_media_asset_resources_on_asset_and_resource'
      add_index :external_media_asset_resources,
                :external_resource_id,
                name: 'index_ext_media_asset_resources_on_resource'
      add_foreign_key :external_media_asset_resources, :external_media_assets,
                      on_delete: :cascade, name: 'fk_ext_media_asset_resources_asset'
      add_foreign_key :external_media_asset_resources, :external_resources,
                      on_delete: :cascade, name: 'fk_ext_media_asset_resources_resource'
    end
  end

  def down
    safety_assured do
      execute "SET lock_timeout = '5s'"
      drop_table :external_media_asset_resources
      execute 'DROP INDEX IF EXISTS index_ext_media_assets_on_image_revalidate'
      execute 'ALTER TABLE external_media_assets DROP CONSTRAINT IF EXISTS external_media_assets_revalidate_attempt_check'
      execute 'ALTER TABLE external_media_assets DROP CONSTRAINT IF EXISTS external_media_assets_generation_check'
      remove_column :external_media_assets, :generation
      remove_column :external_media_assets, :revalidate_attempt
      remove_column :external_media_assets, :revalidate_after
      remove_column :external_media_assets, :validated_at
      remove_column :external_media_assets, :validator_last_modified
      remove_column :external_media_assets, :validator_etag
    end
  end
end
