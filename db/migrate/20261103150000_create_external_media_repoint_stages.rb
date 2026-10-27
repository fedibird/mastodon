# frozen_string_literal: true

# Ownership for one MediaAttachment copied during a generation swap
# (issue #588, P3-A). The row is the only proof that this process may
# delete that file. A new table does not rewrite existing attachments.
class CreateExternalMediaRepointStages < ActiveRecord::Migration[6.1]
  def change
    create_table :external_media_repoint_stages do |t|
      t.bigint :media_attachment_id, null: false
      t.bigint :external_media_asset_id, null: false
      t.bigint :external_status_projection_id, null: false
      t.bigint :account_id, null: false
      t.bigint :status_id, null: false
      t.datetime :lease_until, null: false, precision: 6
      t.timestamps precision: 6
    end

    add_index :external_media_repoint_stages, :media_attachment_id,
              unique: true, name: 'index_ext_media_repoint_stages_on_attachment'
    add_index :external_media_repoint_stages,
              [:external_status_projection_id, :external_media_asset_id],
              name: 'index_ext_media_repoint_stages_on_projection'
    add_foreign_key :external_media_repoint_stages, :external_media_assets,
                    name: 'fk_ext_media_repoint_stages_asset', on_delete: :cascade
    add_foreign_key :external_media_repoint_stages, :external_status_projections,
                    name: 'fk_ext_media_repoint_stages_projection', on_delete: :cascade
  end
end
