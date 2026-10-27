# frozen_string_literal: true

# A purge deletes the projection, and generation GC may delete the asset.
# CASCADE on those foreign keys deleted the only proof that a prepared
# MediaAttachment may be removed, so the file was left with status_id NULL.
# The stage row stays. The parent id becomes NULL. Release still requires
# the media attachment id, the account, and the recorded status.
class KeepExternalMediaRepointStageProof < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      change_column_null :external_media_repoint_stages, :external_media_asset_id, true
      change_column_null :external_media_repoint_stages, :external_status_projection_id, true
      remove_foreign_key :external_media_repoint_stages, name: 'fk_ext_media_repoint_stages_asset'
      remove_foreign_key :external_media_repoint_stages, name: 'fk_ext_media_repoint_stages_projection'
      add_foreign_key :external_media_repoint_stages, :external_media_assets,
                      name: 'fk_ext_media_repoint_stages_asset', on_delete: :nullify
      add_foreign_key :external_media_repoint_stages, :external_status_projections,
                      name: 'fk_ext_media_repoint_stages_projection', on_delete: :nullify
      add_index :external_media_repoint_stages, [:lease_until, :id],
                name: 'index_ext_media_repoint_stages_on_lease'
    end
  end

  def down
    safety_assured do
      execute "SET lock_timeout = '5s'"
      remove_index :external_media_repoint_stages, name: 'index_ext_media_repoint_stages_on_lease'
      # Rows whose parent was already deleted cannot satisfy NOT NULL.
      # The MediaAttachment files are not deleted here.
      execute <<~SQL.squish
        DELETE FROM external_media_repoint_stages
        WHERE external_media_asset_id IS NULL
           OR external_status_projection_id IS NULL
      SQL
      remove_foreign_key :external_media_repoint_stages, name: 'fk_ext_media_repoint_stages_asset'
      remove_foreign_key :external_media_repoint_stages, name: 'fk_ext_media_repoint_stages_projection'
      change_column_null :external_media_repoint_stages, :external_media_asset_id, false
      change_column_null :external_media_repoint_stages, :external_status_projection_id, false
      add_foreign_key :external_media_repoint_stages, :external_media_assets,
                      name: 'fk_ext_media_repoint_stages_asset', on_delete: :cascade
      add_foreign_key :external_media_repoint_stages, :external_status_projections,
                      name: 'fk_ext_media_repoint_stages_projection', on_delete: :cascade
    end
  end
end
