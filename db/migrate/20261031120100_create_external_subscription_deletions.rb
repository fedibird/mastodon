# frozen_string_literal: true

# Asynchronous RSS/Atom unsubscribe (issue #575).
#
# external_subscriptions gains a fourth state, `deleting`. It is a fence: the
# row stays until every projection of the subscription is physically gone, and
# no writer may move it back to another state. The table is small and the
# CHECK is replaced with NOT VALID then VALIDATE so the swap holds only a short
# lock. Nothing here touches, rewrites, or backfills `statuses`.
#
# external_subscription_deletions is the owner-visible job and progress record.
# external_subscription_id is deliberately NOT a foreign key: the subscription
# row is destroyed as the last step of the job and the record must outlive it.
# user_id cascades, so deleting a user also removes its progress records.
#
# next_run_at is the durable outbox. A row that is queued, running, or failed
# with attempts left and whose next_run_at has arrived is re-enqueued by the
# recovery scheduler, so a refused Sidekiq push or a killed worker cannot leave
# a subscription in `deleting` forever.
class CreateExternalSubscriptionDeletions < ActiveRecord::Migration[6.1]
  STATE_CHECK = 'external_subscriptions_state_check'
  OLD_STATES = %w(active paused error).freeze
  NEW_STATES = (OLD_STATES + %w(deleting)).freeze

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      replace_state_check(NEW_STATES)

      create_table :external_subscription_deletions do |t|
        t.bigint :user_id, null: false
        t.bigint :external_subscription_id, null: false
        t.bigint :external_source_id, null: false
        t.string :state, null: false, default: 'queued'
        t.bigint :total_count
        t.bigint :deleted_count, null: false, default: 0
        t.jsonb :route_targets, null: false, default: []
        t.integer :attempt_count, null: false, default: 0
        t.string :last_error_code
        t.datetime :next_run_at
        t.datetime :requested_at, null: false
        t.datetime :started_at
        t.datetime :last_progress_at
        t.datetime :finished_at
        t.timestamps
      end

      add_index :external_subscription_deletions, :external_subscription_id,
                unique: true, name: 'index_external_subscription_deletions_on_subscription'
      add_index :external_subscription_deletions, [:user_id, :id],
                name: 'index_external_subscription_deletions_on_user'
      add_index :external_subscription_deletions, :next_run_at,
                where: "state IN ('queued', 'running', 'failed')",
                name: 'index_external_subscription_deletions_on_pending'
      add_index :external_subscription_deletions, :finished_at,
                where: "state = 'completed'",
                name: 'index_external_subscription_deletions_on_completed'
      add_foreign_key :external_subscription_deletions, :users,
                      column: :user_id, on_delete: :cascade, name: 'fk_external_subscription_deletions_user'
      add_check_constraint :external_subscription_deletions,
                           "state IN ('queued', 'running', 'completed', 'failed')",
                           name: 'external_subscription_deletions_state_check'
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      pending = select_value(<<~SQL.squish)
        SELECT 1 WHERE EXISTS (SELECT 1 FROM external_subscriptions WHERE state = 'deleting')
                    OR EXISTS (SELECT 1 FROM external_subscription_deletions WHERE state <> 'completed')
      SQL
      if pending
        raise ActiveRecord::IrreversibleMigration,
              'Unsubscribe jobs are still running. Let them finish before rolling this migration back.'
      end

      drop_table :external_subscription_deletions
      replace_state_check(OLD_STATES)
    end
  end

  private

  def replace_state_check(states)
    list = states.map { |state| connection.quote(state) }.join(', ')
    execute "ALTER TABLE external_subscriptions DROP CONSTRAINT IF EXISTS #{STATE_CHECK}"
    execute "ALTER TABLE external_subscriptions ADD CONSTRAINT #{STATE_CHECK} CHECK (state IN (#{list})) NOT VALID"
    execute "ALTER TABLE external_subscriptions VALIDATE CONSTRAINT #{STATE_CHECK}"
  end
end
