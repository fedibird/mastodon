# frozen_string_literal: true

class AddDispatchCohortToFollowImportBatches < ActiveRecord::Migration[6.1]
  def change
    # Durable scheduler-cohort provenance, independent of dispatch_owner.
    # Existing rows and unspecified inserts stay historical (0). The
    # I2-aware recorder writes operational (1) only for newly created
    # batches. On PostgreSQL 11+ a constant-default integer is metadata-only.
    safety_assured do
      add_column :follow_import_batches, :dispatch_cohort, :integer, null: false, default: 0
    end
  end
end
