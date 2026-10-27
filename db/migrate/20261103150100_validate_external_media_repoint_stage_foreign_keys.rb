# frozen_string_literal: true

# Validate the foreign keys created without validation by
# CreateExternalMediaRepointStages. Separate from creation so adding the
# constraint does not block writes on external_media_assets and
# external_status_projections.
class ValidateExternalMediaRepointStageForeignKeys < ActiveRecord::Migration[6.1]
  def up
    validate_foreign_key :external_media_repoint_stages, :external_media_assets,
                         name: 'fk_ext_media_repoint_stages_asset'
    validate_foreign_key :external_media_repoint_stages, :external_status_projections,
                         name: 'fk_ext_media_repoint_stages_projection'
  end

  def down
    # Validation does not change the constraint's delete behavior.
    # Rolling back the previous migration removes the foreign keys.
  end
end
