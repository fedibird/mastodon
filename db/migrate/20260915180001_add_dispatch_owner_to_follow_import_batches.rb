# frozen_string_literal: true

class AddDispatchOwnerToFollowImportBatches < ActiveRecord::Migration[6.1]
  def change
    # Durable dispatch ownership. Existing and unspecified new rows are
    # legacy (0). Application code selects scheduler (1) only for NEW
    # batches created while FOLLOW_IMPORT_DISPATCH_GLOBAL=true.
    # On PostgreSQL 11+ a constant-default integer is metadata-only.
    safety_assured do
      add_column :follow_import_batches, :dispatch_owner, :integer, null: false, default: 0
    end
  end
end
