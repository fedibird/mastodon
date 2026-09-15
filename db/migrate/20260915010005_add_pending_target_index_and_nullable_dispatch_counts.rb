# frozen_string_literal: true

class AddPendingTargetIndexAndNullableDispatchCounts < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      # Global pending / active-batch telemetry (`DispatchCounts.global_pending`
      # and `.active_batches`) filters FollowImportTarget by state=pending only.
      # The existing (batch_id, state) index is prefix-batch and cannot scan
      # "all pending rows" cheaply once historical (non-pending) targets grow.
      # A partial index on batch_id for pending rows stays compact (only the
      # live dispatchable set) and supports both COUNT(*) and
      # COUNT(DISTINCT batch_id) WHERE state = pending.
      add_index :follow_import_targets, :batch_id,
                where: 'state = 0',
                algorithm: :concurrently,
                name: :index_follow_import_targets_on_pending_batch_id

      # Interrupted / failed measurements must stay NULL, not a fake 0.
      change_column_null :follow_import_dispatch_observations, :candidate_count, true
      change_column_default :follow_import_dispatch_observations, :candidate_count, from: 0, to: nil
      change_column_null :follow_import_dispatch_observations, :claimed_count, true
      change_column_default :follow_import_dispatch_observations, :claimed_count, from: 0, to: nil
      add_column :follow_import_dispatch_observations, :pass_error_class, :string

      change_column_null :follow_import_transport_observations, :duration_ms, true
    end
  end

  def down
    safety_assured do
      change_column_null :follow_import_transport_observations, :duration_ms, false

      remove_column :follow_import_dispatch_observations, :pass_error_class
      change_column_default :follow_import_dispatch_observations, :claimed_count, from: nil, to: 0
      change_column_null :follow_import_dispatch_observations, :claimed_count, false
      change_column_default :follow_import_dispatch_observations, :candidate_count, from: nil, to: 0
      change_column_null :follow_import_dispatch_observations, :candidate_count, false

      remove_index :follow_import_targets, name: :index_follow_import_targets_on_pending_batch_id
    end
  end
end
