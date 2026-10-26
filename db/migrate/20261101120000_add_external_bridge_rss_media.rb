# frozen_string_literal: true

# Article media for external RSS/Atom projections (issue #585).
#
# external_resources gains a nullable media_revision and a jsonb candidate
# list. Both are catalog-only on PostgreSQL 11+ (the jsonb default is a
# constant). external_status_projections gains a nullable
# last_seen_media_revision. No existing row is rewritten and no index is
# added to those large-ish tables: candidates are read with the resource
# row the importer already loads.
#
# external_media_assets is the shared, URL-keyed download. One row per
# normalized URL. external_projection_attachments is the per-projection
# reference to a normal MediaAttachment. The shared file and the owner's
# attachment are different rows so a purge of one subscriber cannot delete
# another subscriber's bytes, and MediaAttachment stays owned by one account.
class AddExternalBridgeRSSMedia < ActiveRecord::Migration[6.1]
  # strong_migrations cannot inspect change_table bulk: true, so each column is
  # its own catalog-only statement.
  # rubocop:disable Rails/BulkChangeTable
  def change
    add_column :external_resources, :media_revision, :text
    add_column :external_resources, :media_candidates, :jsonb, null: false, default: []
    add_column :external_status_projections, :last_seen_media_revision, :text

    create_table :external_media_assets do |t|
      t.string :url_digest, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: 'ready'
      t.string :content_type
      t.bigint :byte_size
      t.string :fingerprint
      t.integer :width
      t.integer :height
      t.string :failure_code
      t.string :failed_revision
      t.integer :attempt_count, null: false, default: 0
      t.datetime :fetched_at
      t.string :file_file_name
      t.string :file_content_type
      t.bigint :file_file_size
      t.datetime :file_updated_at
      t.timestamps
      t.index :url_digest, unique: true, name: 'index_external_media_assets_on_url_digest'
    end

    create_table :external_projection_attachments do |t|
      t.bigint :external_status_projection_id, null: false
      t.bigint :external_media_asset_id, null: false
      t.bigint :media_attachment_id, null: false
      t.integer :position, null: false, default: 0
      t.string :kind, null: false
      t.timestamps
    end

    add_index :external_projection_attachments,
              [:external_status_projection_id, :external_media_asset_id],
              unique: true,
              name: 'index_ext_proj_attachments_on_proj_and_asset'
    add_index :external_projection_attachments,
              :media_attachment_id,
              unique: true,
              name: 'index_ext_proj_attachments_on_media_attachment'
    add_index :external_projection_attachments,
              :external_media_asset_id,
              name: 'index_ext_proj_attachments_on_asset'

    add_foreign_key :external_projection_attachments, :external_status_projections,
                    name: 'fk_ext_proj_attach_projection', on_delete: :cascade, validate: false
    add_foreign_key :external_projection_attachments, :external_media_assets,
                    name: 'fk_ext_proj_attach_asset', on_delete: :restrict, validate: false
    add_foreign_key :external_projection_attachments, :media_attachments,
                    name: 'fk_ext_proj_attach_media', on_delete: :restrict, validate: false
  end
  # rubocop:enable Rails/BulkChangeTable
end
