# frozen_string_literal: true

class CreatePostDrafts < ActiveRecord::Migration[6.1]
  # New empty table. No rewrite of statuses, media, or scheduled posts.
  # The check is validated immediately because the table starts empty.
  def change
    create_table :post_drafts do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false, type: :bigint
      t.string :client_uuid, null: false, limit: 36
      t.integer :schema_version, null: false
      t.integer :revision, null: false, default: 1
      t.jsonb :payload, null: false, default: {}
      t.string :state, null: false, default: 'active', limit: 16

      t.timestamps

      t.index [:account_id, :client_uuid], unique: true, name: 'index_post_drafts_on_account_id_and_client_uuid'
      t.index [:account_id, :updated_at, :id], name: 'index_post_drafts_on_account_updated_at_and_id'
      t.check_constraint <<~SQL.squish, name: 'post_drafts_shape'
        client_uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND schema_version = 1
        AND revision >= 1
        AND state = 'active'
        AND octet_length(payload::text) <= 32768
      SQL
    end
  end
end
