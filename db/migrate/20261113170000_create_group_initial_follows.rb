# frozen_string_literal: true

# One row per approval that should attempt the founding owner's follow.
# Approvals that already exist are not backfilled, and this migration does
# not insert or update follows. The hot follows table is not locked: the
# stored follow id is an observation, not a foreign key, so unfollowing
# cannot delete this row or clear the discharge timestamp.
class CreateGroupInitialFollows < ActiveRecord::Migration[6.1]
  CHECK = 'group_initial_follows_state_shape'
  OPEN_INDEX = 'index_group_initial_follows_on_open_state'

  # pending: not started. last_error may record an enqueue miss.
  # processing: a worker holds the row. The discharge timestamp may already
  # be set when the follow committed and the terminal marker has not.
  # succeeded / completed: the obligation is finished. follow ids may be
  # stale after a later unfollow.
  # retryable_failure: no relationship was recorded.
  # permanent_failure: do not try again until an administrator reopens it.
  SHAPE_SQL = <<~SQL.squish
    attempts >= 0
    AND (outcome IS NULL OR outcome ~ '^[a-z0-9_]{1,64}$')
    AND (last_error IS NULL OR last_error ~ '^[a-z0-9_]{1,64}$')
    AND NOT (follow_id IS NOT NULL AND follow_request_id IS NOT NULL)
    AND (
      (
        state = 0
        AND relationship_recorded_at IS NULL
        AND follow_id IS NULL
        AND follow_request_id IS NULL
        AND finished_at IS NULL
        AND outcome IS NULL
        AND (last_error IS NULL OR last_error = 'enqueue_failed')
      )
      OR (
        state = 1
        AND finished_at IS NULL
        AND (
          (
            relationship_recorded_at IS NULL
            AND follow_id IS NULL
            AND follow_request_id IS NULL
            AND outcome IS NULL
          )
          OR (relationship_recorded_at IS NOT NULL AND outcome IS NOT NULL)
        )
      )
      OR (
        state IN (2, 4)
        AND relationship_recorded_at IS NOT NULL
        AND finished_at IS NOT NULL
        AND outcome IS NOT NULL
        AND last_error IS NULL
      )
      OR (
        state = 3
        AND relationship_recorded_at IS NULL
        AND follow_id IS NULL
        AND follow_request_id IS NULL
        AND finished_at IS NULL
        AND last_error IS NOT NULL
      )
      OR (
        state = 5
        AND relationship_recorded_at IS NULL
        AND follow_id IS NULL
        AND follow_request_id IS NULL
        AND finished_at IS NOT NULL
        AND last_error IS NOT NULL
        AND outcome IS NULL
      )
    )
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      create_table :group_initial_follows do |t|
        t.references :group_creation_request, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true, name: 'index_group_initial_follows_on_request_id' }
        t.integer :state, null: false, default: 0
        t.string :outcome, limit: 64
        t.string :last_error, limit: 64
        t.bigint :follow_id
        t.bigint :follow_request_id
        t.datetime :relationship_recorded_at
        t.datetime :claim_expires_at
        t.integer :attempts, null: false, default: 0
        t.datetime :finished_at
        t.timestamps
      end
      add_index :group_initial_follows, :state, where: 'state IN (0, 1, 3)', name: OPEN_INDEX
      add_check_constraint :group_initial_follows, SHAPE_SQL, name: CHECK
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      remove_check_constraint :group_initial_follows, name: CHECK
      remove_index :group_initial_follows, name: OPEN_INDEX
      drop_table :group_initial_follows
    end
  end
end
