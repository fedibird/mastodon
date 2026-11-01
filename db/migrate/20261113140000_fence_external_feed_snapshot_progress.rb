# frozen_string_literal: true

# Lease fencing, isolated remainder, and batched catch-up for RSS snapshots.
#
# isolated_positions records keyed positions that were not imported after
# the attempt ceiling. retry_positions is the explicit retry queue. Neither
# is filled by an automatic loop. busy_retry_at caps one delayed re-entry
# while a lease is still held.
#
# state gains incomplete: the cursor finished and at least one position was
# isolated. failed with next_index still below item_count blocks newer
# generations until FeedSnapshot::Retry. This migration does not rewrite
# resources or projections.
#
# external_feed_catch_ups is one cursor per subscription. Resume enqueues a
# batch instead of walking every retained body in the request.
#
# Rollback drops the catch-up table and the new columns. A snapshot left
# incomplete or failed keeps that state only if the check constraint is
# restored after those rows are completed or removed. This branch has not
# shipped, so the down path drops the columns after restoring the original
# state check.
class FenceExternalFeedSnapshotProgress < ActiveRecord::Migration[6.1]
  def up
    # strong_migrations cannot inspect change_table bulk: true.
    # rubocop:disable Rails/BulkChangeTable
    add_column :external_feed_snapshots, :isolated_positions, :jsonb, null: false, default: []
    add_column :external_feed_snapshots, :retry_positions, :jsonb, null: false, default: []
    add_column :external_feed_snapshots, :busy_retry_at, :datetime
    remove_check_constraint :external_feed_snapshots, name: 'external_feed_snapshots_state_check'
    # The table was added in the previous migration on this branch and is empty
    # in production. Validating it does not rewrite existing feed rows.
    safety_assured do
      add_check_constraint :external_feed_snapshots,
                           "state IN ('pending', 'draining', 'complete', 'incomplete', 'failed')",
                           name: 'external_feed_snapshots_state_check'
    end
    create_catch_ups
    # rubocop:enable Rails/BulkChangeTable
  end

  def down
    # rubocop:disable Rails/BulkChangeTable
    drop_table :external_feed_catch_ups
    remove_check_constraint :external_feed_snapshots, name: 'external_feed_snapshots_state_check'
    safety_assured do
      add_check_constraint :external_feed_snapshots,
                           "state IN ('pending', 'draining', 'complete', 'failed')",
                           name: 'external_feed_snapshots_state_check'
    end
    remove_column :external_feed_snapshots, :busy_retry_at
    remove_column :external_feed_snapshots, :retry_positions
    remove_column :external_feed_snapshots, :isolated_positions
    # rubocop:enable Rails/BulkChangeTable
  end

  private

  def create_catch_ups
    create_table :external_feed_catch_ups do |t|
      t.references :external_subscription, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.bigint :external_feed_snapshot_id
      t.integer :position, null: false, default: 0
      t.string :state, null: false, default: 'pending'
      t.string :lease_token
      t.datetime :lease_expires_at
      t.timestamps
    end
    add_index :external_feed_catch_ups, :external_feed_snapshot_id, name: 'index_external_feed_catch_ups_on_snapshot'
    safety_assured do
      add_check_constraint :external_feed_catch_ups,
                           "state IN ('pending', 'running', 'done', 'stopped') AND position >= 0",
                           name: 'external_feed_catch_ups_progress_check'
    end
  end
end
