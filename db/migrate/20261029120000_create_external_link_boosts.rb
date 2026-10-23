# frozen_string_literal: true

# E4-B boost state. One row per share generation of a projection by one User.
# The row is the source of truth for reblogged and for the Undo right. A
# wrapper Status is never matched by Account and reference Status alone.
#
# The feature flag and testers stay off. Nothing here is backfilled.
class CreateExternalLinkBoosts < ActiveRecord::Migration[6.1]
  UNANNOUNCED_INDEX_SQL = <<~SQL
    CREATE INDEX IF NOT EXISTS index_link_boosts_on_unannounced
    ON external_projection_link_boosts (next_announce_at ASC NULLS FIRST, id)
    WHERE announced_at IS NULL
      AND state = 'active'
      AND wrapper_status_id IS NOT NULL
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_reference_digest
      create_boosts
      execute ExternalBridge::Schema::LINK_BOOST_SQL
    end
  end

  def add_reference_digest
    return if column_exists?(:external_projection_link_references, :reference_digest)

    add_column :external_projection_link_references, :reference_digest, :string, limit: 64
  end

  def create_boosts
    create_table :external_projection_link_boosts do |t|
      t.bigint :user_id, null: false
      t.bigint :account_id, null: false
      t.bigint :link_reference_id, null: false
      t.bigint :external_status_projection_id
      t.bigint :projection_status_id, null: false
      t.bigint :reference_status_id
      t.bigint :wrapper_status_id
      t.string :visibility, null: false
      t.integer :generation, null: false
      t.integer :policy_revision, null: false
      t.string :state, null: false, default: 'active'
      t.string :ended_reason
      t.datetime :announced_at
      t.datetime :next_announce_at
      t.datetime :undone_at
      t.timestamps
    end
    add_boost_indexes
    add_boost_keys
    add_boost_checks
    execute UNANNOUNCED_INDEX_SQL
  end

  def add_boost_indexes
    add_index :external_projection_link_boosts,
              [:user_id, :projection_status_id],
              unique: true,
              where: "state = 'active'",
              name: 'index_link_boosts_on_active_share'
    add_index :external_projection_link_boosts,
              [:link_reference_id, :generation],
              unique: true,
              name: 'index_link_boosts_on_generation'
    add_index :external_projection_link_boosts,
              :wrapper_status_id,
              unique: true,
              where: 'wrapper_status_id IS NOT NULL',
              name: 'index_link_boosts_on_wrapper'
    add_index :external_projection_link_boosts,
              :reference_status_id,
              where: 'reference_status_id IS NOT NULL',
              name: 'index_link_boosts_on_reference'
    add_index :external_projection_link_boosts, :user_id, name: 'index_link_boosts_on_user_id'
    add_index :external_projection_link_boosts,
              :id,
              where: "state = 'active' AND external_status_projection_id IS NULL",
              name: 'index_link_boosts_on_orphaned'
  end

  def add_boost_keys
    add_foreign_key :external_projection_link_boosts, :users, column: :user_id, on_delete: :cascade, name: 'fk_link_boosts_user'
    add_foreign_key :external_projection_link_boosts, :accounts, column: :account_id, on_delete: :cascade, name: 'fk_link_boosts_account'
    add_foreign_key :external_projection_link_boosts, :external_projection_link_references, column: :link_reference_id, on_delete: :cascade, name: 'fk_link_boosts_reference_row'
    add_foreign_key :external_projection_link_boosts, :external_status_projections, column: :external_status_projection_id, on_delete: :nullify, name: 'fk_link_boosts_projection'
    add_foreign_key :external_projection_link_boosts, :statuses, column: :reference_status_id, on_delete: :nullify, name: 'fk_link_boosts_reference_status'
    add_foreign_key :external_projection_link_boosts, :statuses, column: :wrapper_status_id, on_delete: :nullify, name: 'fk_link_boosts_wrapper'
  end

  def add_boost_checks
    add_check_constraint :external_projection_link_boosts,
                         "visibility IN ('public', 'unlisted')",
                         name: 'link_boosts_visibility_check'
    add_check_constraint :external_projection_link_boosts,
                         "state IN ('active', 'undone')",
                         name: 'link_boosts_state_check'
    add_check_constraint :external_projection_link_boosts,
                         'generation >= 1',
                         name: 'link_boosts_generation_check'
    add_check_constraint :external_projection_link_boosts,
                         "state <> 'active' OR wrapper_status_id IS NOT NULL",
                         name: 'link_boosts_active_requires_wrapper'
    add_check_constraint :external_projection_link_boosts,
                         "state <> 'undone' OR undone_at IS NOT NULL",
                         name: 'link_boosts_undone_requires_time'
    add_check_constraint :external_projection_link_boosts,
                         "state = 'undone' OR ended_reason IS NULL",
                         name: 'link_boosts_reason_requires_end'
  end

  def down
    safety_assured do
      ActiveRecord::Base.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        execute ExternalBridge::Schema::LINK_BOOST_ROLLBACK_FLOOR_SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS external_projection_link_boosts_end_on_status_delete ON statuses;
          DROP TRIGGER IF EXISTS external_projection_link_boosts_enforce_owner ON external_projection_link_boosts;
          DROP TRIGGER IF EXISTS external_projection_link_references_digest_mark ON external_projection_link_references;
        SQL
        drop_table :external_projection_link_boosts, if_exists: true
        execute <<~SQL
          DROP FUNCTION IF EXISTS external_projection_link_boosts_end_on_status_delete();
          DROP FUNCTION IF EXISTS external_projection_link_boosts_enforce_owner();
          DROP FUNCTION IF EXISTS external_projection_link_references_digest_mark();
        SQL
        if column_exists?(:external_projection_link_references, :reference_digest)
          remove_column :external_projection_link_references, :reference_digest
        end
      end
    end
  end
end
