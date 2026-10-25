# frozen_string_literal: true

# Recovery of a lost RemovalWorker push for an ended share (RecoverRemovals).
#
# removal_acknowledged_at is the durable acknowledgement: RemovalWorker sets it
# when RemoveStatusService returned for the wrapper (the Undo has been handed
# to ActivityPub delivery). A wrapper that Mastodon keeps on purpose, for
# example one inside an unresolved report, is discarded but not destroyed, so
# "the wrapper still exists" cannot mean "not done". removal_next_attempt_at
# is the claim of the recovery push; it is separate from next_announce_at,
# which still holds the 30 minute Announce claim when a share ends early.
#
# Two nullable columns without defaults (no rewrite) and one partial index that
# holds only ended shares still waiting for that acknowledgement. Built
# CONCURRENTLY; nothing else is touched.
class AddExternalLinkBoostPendingRemovalIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  INDEX = 'index_link_boosts_on_pending_removal'

  def up
    safety_assured do
      add_column :external_projection_link_boosts, :removal_acknowledged_at, :datetime, if_not_exists: true
      add_column :external_projection_link_boosts, :removal_next_attempt_at, :datetime, if_not_exists: true
    end
    add_index :external_projection_link_boosts, :updated_at,
              where: "state = 'undone' AND wrapper_status_id IS NOT NULL AND removal_acknowledged_at IS NULL",
              name: INDEX,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :external_projection_link_boosts, name: INDEX, algorithm: :concurrently, if_exists: true
    safety_assured do
      remove_column :external_projection_link_boosts, :removal_next_attempt_at, if_exists: true
      remove_column :external_projection_link_boosts, :removal_acknowledged_at, if_exists: true
    end
  end
end
