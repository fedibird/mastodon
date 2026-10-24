# frozen_string_literal: true

# E4-C gate. The monotonic (revision, reblogged) pair of a projection for one
# User. A trigger on external_projection_link_boosts is the only writer, so the
# pair moves in the same statement as the boost row.
#
# Nothing here rewrites or backfills `statuses`. Existing active shares (the
# table is empty while the flag has never been on) are copied once as
# revision 1, already marked as notified. The feature flag and testers stay off.
#
# `notified_revision` is the durable outbox of the owner event. A row whose
# revision is above it has a flip that no stream event has covered yet, for
# example a wrapper that was deleted with plain SQL. The partial index holds
# only those rows.
class CreateExternalLinkBoostStates < ActiveRecord::Migration[6.1]
  BACKFILL_SQL = <<~SQL
    INSERT INTO external_projection_link_boost_states
      (user_id, projection_status_id, revision, notified_revision, reblogged, created_at, updated_at)
    SELECT DISTINCT ON (boosts.user_id, boosts.projection_status_id)
           boosts.user_id, boosts.projection_status_id, 1, 1, TRUE, clock_timestamp(), clock_timestamp()
      FROM external_projection_link_boosts boosts
      INNER JOIN statuses wrappers ON wrappers.id = boosts.wrapper_status_id
     WHERE boosts.state = 'active'
       AND wrappers.deleted_at IS NULL
    ON CONFLICT (user_id, projection_status_id) DO NOTHING
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      create_states
      execute ExternalBridge::Schema::LINK_BOOST_STATE_SQL
      execute BACKFILL_SQL
    end
  end

  def create_states
    create_table :external_projection_link_boost_states, primary_key: [:user_id, :projection_status_id] do |t|
      t.bigint :user_id, null: false
      t.bigint :projection_status_id, null: false
      t.bigint :revision, null: false
      t.bigint :notified_revision, null: false, default: 0
      t.boolean :reblogged, null: false
      t.timestamps
    end
    add_index :external_projection_link_boost_states,
              :projection_status_id,
              name: 'index_link_boost_states_on_projection_status'
    add_index :external_projection_link_boost_states,
              :updated_at,
              where: 'revision > notified_revision',
              name: 'index_link_boost_states_on_unnotified'
    add_foreign_key :external_projection_link_boost_states, :users, column: :user_id, on_delete: :cascade, name: 'fk_link_boost_states_user'
    add_check_constraint :external_projection_link_boost_states,
                         'revision >= 1',
                         name: 'link_boost_states_revision_check'
    add_check_constraint :external_projection_link_boost_states,
                         'notified_revision >= 0 AND notified_revision <= revision',
                         name: 'link_boost_states_notified_check'
  end

  def down
    safety_assured do
      ActiveRecord::Base.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        execute ExternalBridge::Schema::LINK_BOOST_STATE_ROLLBACK_FLOOR_SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS statuses_end_link_boost_on_discard ON statuses;
          DROP TRIGGER IF EXISTS external_projection_link_boosts_track_state ON external_projection_link_boosts;
        SQL
        drop_table :external_projection_link_boost_states, if_exists: true
        execute <<~SQL
          DROP FUNCTION IF EXISTS statuses_end_link_boost_on_discard();
          DROP FUNCTION IF EXISTS external_projection_link_boosts_track_state();
        SQL
      end
    end
  end
end
