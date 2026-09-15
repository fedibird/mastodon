# frozen_string_literal: true

class AddPendingTargetPositionIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    safety_assured do
      # Shadow PendingTargetFeed walks:
      #   WHERE batch_id = ? AND state = pending ORDER BY position, id LIMIT n
      # The pending batch_id partial index finds the batch's live rows but
      # still sorts them. This ordered partial index lets a 20k-target
      # batch satisfy the windowed scan without a full-batch sort.
      add_index :follow_import_targets, [:batch_id, :position, :id],
                where: 'state = 0',
                algorithm: :concurrently,
                name: :index_follow_import_targets_on_pending_batch_position
    end
  end
end
