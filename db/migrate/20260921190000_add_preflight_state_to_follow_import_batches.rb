# frozen_string_literal: true

class AddPreflightStateToFollowImportBatches < ActiveRecord::Migration[6.1]
  def change
    # Durable preflight execution barrier. Existing rows and unspecified
    # inserts stay ready (1) so current batches remain executable. The
    # recorder writes screening (0) only for newly created operational
    # batches. On PostgreSQL 11+ a constant-default integer is metadata-only.
    safety_assured do
      add_column :follow_import_batches, :preflight_state, :integer, null: false, default: 1
    end
  end
end
