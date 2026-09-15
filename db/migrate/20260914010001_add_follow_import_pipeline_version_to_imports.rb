# frozen_string_literal: true

# Nullable pipeline marker for Follow Import recovery safety.
#
# NULL  = legacy / provenance unknown. Automatic recovery is forbidden.
# 1     = created by the current DB-backed Follow Import pipeline. Recovery-aware.
#
# Existing rows stay NULL on purpose. Do not backfill: leftover pre-pipeline
# Imports must remain unmarked so the watchdog cannot re-run them.
class AddFollowImportPipelineVersionToImports < ActiveRecord::Migration[6.1]
  def change
    add_column :imports, :follow_import_pipeline_version, :integer
  end
end
