# frozen_string_literal: true

# Validate the foreign keys created without validation by AddExternalBridgeRSSMedia.
# Keep validation separate from constraint creation to minimize write blocking.
class ValidateExternalBridgeRSSMediaForeignKeys < ActiveRecord::Migration[6.1]
  def change
    validate_foreign_key :external_projection_attachments, :external_status_projections,
                         name: 'fk_ext_proj_attach_projection'
    validate_foreign_key :external_projection_attachments, :external_media_assets,
                         name: 'fk_ext_proj_attach_asset'
    validate_foreign_key :external_projection_attachments, :media_attachments,
                         name: 'fk_ext_proj_attach_media'
  end
end
