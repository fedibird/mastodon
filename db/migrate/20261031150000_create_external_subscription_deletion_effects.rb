# frozen_string_literal: true

# One row per projection status deleted by an asynchronous unsubscribe.
#
# The physical DELETE removes the marker, so the status id (and, when the
# status was external, its home/list destinations) has to be durable in the
# same transaction. Cache, search, and the stream enqueue are stamped
# separately. A row stays until all three have succeeded, which is what lets a
# later run finish cache or search after Sidekiq has already accepted the
# delete event.
#
# Rows are inserted per batch and deleted when that batch's effects are done.
# The runner stops further deletes while a bounded number are still open, so a
# refused stream enqueue cannot accumulate one jsonb document, or one row per
# status of a hundred-thousand-item subscription.
#
# This version replaces an unmerged jsonb column on the deletion row. If that
# column was applied from the previous file, roll that file back (it only
# removes the column) before migrating this one.
class CreateExternalSubscriptionDeletionEffects < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      if column_exists?(:external_subscription_deletions, :pending_stream_deletes)
        remove_column :external_subscription_deletions, :pending_stream_deletes
      end

      create_table :external_subscription_deletion_effects do |t|
        t.bigint :external_subscription_deletion_id, null: false
        t.bigint :status_id, null: false
        t.jsonb :destinations
        t.datetime :cache_cleared_at
        t.datetime :search_cleared_at
        t.datetime :stream_enqueued_at
        t.timestamps
      end

      add_index :external_subscription_deletion_effects,
                [:external_subscription_deletion_id, :status_id],
                unique: true,
                name: 'index_deletion_effects_on_deletion_and_status'
      add_foreign_key :external_subscription_deletion_effects, :external_subscription_deletions,
                      column: :external_subscription_deletion_id,
                      on_delete: :cascade,
                      name: 'fk_deletion_effects_deletion'
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      drop_table :external_subscription_deletion_effects
    end
  end
end
