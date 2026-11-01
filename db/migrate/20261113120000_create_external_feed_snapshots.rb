# frozen_string_literal: true

# Durable body and cursor for one fetched RSS/Atom response (issue #638).
#
# The row keeps the response that was already accepted, plus how far import
# has moved through its keyed items. A process restart reads this row. The
# unprocessed tail is not stored only in memory or in a Sidekiq argument.
#
# Validators on external_sources move when the row is stored, including the
# synchronous history page. The tail is imported later, SNAPSHOT_BATCH_ITEMS
# at a time. An older unfinished row is not deleted when a newer response
# arrives. Completed and failed bodies are nulled after
# Limits::SNAPSHOT_BODY_RETENTION by a later capture or drain. This migration
# does not schedule that cleanup and does not rewrite sources, resources, or
# projections.
#
# Rollback drops the table. Resources and projections already written stay.
# After the application rollback, a later fetch uses the previous 40-item
# page again. No backfill and no production flag change is part of this
# migration.
class CreateExternalFeedSnapshots < ActiveRecord::Migration[6.1]
  def change
    create_table :external_feed_snapshots do |t|
      t.references :external_source, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :generation, null: false
      t.string :state, null: false, default: 'pending'
      t.text :etag
      t.text :last_modified
      t.text :body
      t.integer :byte_size, null: false
      t.integer :item_count, null: false, default: 0
      t.integer :next_index, null: false, default: 0
      t.jsonb :history_positions, null: false, default: []
      t.datetime :history_applied_at
      t.string :lease_token
      t.datetime :lease_expires_at
      t.integer :batch_count, null: false, default: 0
      t.integer :attempt_count, null: false, default: 0
      t.string :last_error_code
      t.datetime :completed_at
      t.datetime :body_purged_at
      t.timestamps
    end

    add_index :external_feed_snapshots, [:external_source_id, :generation], unique: true, name: 'index_external_feed_snapshots_on_source_and_generation'
    add_index :external_feed_snapshots, [:external_source_id, :state, :generation], name: 'index_external_feed_snapshots_on_source_state', where: "state IN ('pending', 'draining')"
    add_check_constraint :external_feed_snapshots, "state IN ('pending', 'draining', 'complete', 'failed')", name: 'external_feed_snapshots_state_check'
    add_check_constraint :external_feed_snapshots, 'generation > 0 AND item_count >= 0 AND next_index >= 0 AND next_index <= item_count AND byte_size >= 0 AND batch_count >= 0 AND attempt_count >= 0', name: 'external_feed_snapshots_progress_check'
  end
end
