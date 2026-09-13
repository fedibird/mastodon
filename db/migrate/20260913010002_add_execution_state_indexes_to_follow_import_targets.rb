# frozen_string_literal: true

class AddExecutionStateIndexesToFollowImportTargets < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    # follow_request_uri is the durable correlation key (the ephemeral
    # FollowRequest is destroyed on Accept/Reject). Each executed remote follow
    # has a distinct request URI, so a partial unique index (present rows only)
    # both speeds correlation lookups and guards against duplicate correlation.
    safety_assured do
      add_index :follow_import_targets, :follow_request_uri,
                unique: true,
                where: 'follow_request_uri IS NOT NULL',
                algorithm: :concurrently,
                name: :index_follow_import_targets_on_follow_request_uri

      # Supports per-batch progress aggregation (group by state within a batch).
      add_index :follow_import_targets, [:batch_id, :state],
                algorithm: :concurrently,
                name: :index_follow_import_targets_on_batch_and_state
    end
  end

  def down
    remove_index :follow_import_targets, name: :index_follow_import_targets_on_follow_request_uri
    remove_index :follow_import_targets, name: :index_follow_import_targets_on_batch_and_state
  end
end
