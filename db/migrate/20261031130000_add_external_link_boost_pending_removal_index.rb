# frozen_string_literal: true

# Index for ExternalBridge::LinkSharing::RecoverRemovals: an ended share whose
# wrapper has not been removed yet. A row leaves the index when the wrapper is
# removed (ON DELETE SET NULL on wrapper_status_id), so it stays tiny. Built
# CONCURRENTLY; nothing is rewritten.
class AddExternalLinkBoostPendingRemovalIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    add_index :external_projection_link_boosts, :updated_at,
              where: "state = 'undone' AND wrapper_status_id IS NOT NULL",
              name: 'index_link_boosts_on_pending_removal',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :external_projection_link_boosts, name: 'index_link_boosts_on_pending_removal',
                                                   algorithm: :concurrently,
                                                   if_exists: true
  end
end
