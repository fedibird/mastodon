# frozen_string_literal: true

# Persistence for group creation requests and local role assignments.
# Creates empty tables only. No account backfill, no owner assignment for
# groups that already exist, and no unique lock on a pending username.
class CreateGroupManagementRecords < ActiveRecord::Migration[6.1]
  def change
    create_group_creation_requests
    create_managed_groups
    create_group_role_assignments
  end

  private

  def create_group_creation_requests
    create_table :group_creation_requests do |t|
      t.references :requester_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_creation_requests_on_requester_account_id' }
      t.string :username, null: false, limit: 30
      t.string :display_name, null: false, default: ''
      t.text :note, null: false, default: ''
      t.integer :state, null: false, default: 0
      t.datetime :requested_at, null: false
      t.references :reviewer_account, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_creation_requests_on_reviewer_account_id' }
      t.datetime :reviewed_at
      t.text :decision_note
      t.references :group_account, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { unique: true, name: 'index_group_creation_requests_on_group_account_id' }
      t.references :previous_request, foreign_key: { to_table: :group_creation_requests, on_delete: :restrict }, index: { unique: true, name: 'index_group_creation_requests_on_previous_request_id' }
      t.datetime :cancelled_at
      t.references :initial_owner_account, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_creation_requests_on_initial_owner_account_id' }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :group_creation_requests, :requested_at,
              where: 'state = 0',
              name: 'index_group_creation_requests_on_pending_requested_at'
    add_group_creation_request_username_index
    add_index :group_creation_requests, [:requester_account_id, :requested_at],
              name: 'index_group_creation_requests_on_requester_requested_at'
    add_group_creation_request_checks
  end

  # Non-unique lookup index. It does not reserve a pending username.
  # safety_assured: the table was created empty in this migration, so
  # strong_migrations cannot infer that the expression index is safe.
  def add_group_creation_request_username_index
    reversible do |dir|
      dir.up do
        safety_assured do
          execute <<~SQL.squish
            CREATE INDEX index_group_creation_requests_on_lower_username
            ON group_creation_requests (lower(username))
          SQL
        end
      end

      dir.down do
        safety_assured do
          execute 'DROP INDEX IF EXISTS index_group_creation_requests_on_lower_username'
        end
      end
    end
  end

  def add_group_creation_request_checks
    add_check_constraint :group_creation_requests,
                         "username ~ '^[a-z0-9_]{1,30}$'",
                         name: 'group_creation_requests_username_shape'
    add_check_constraint :group_creation_requests,
                         'previous_request_id IS NULL OR previous_request_id <> id',
                         name: 'group_creation_requests_previous_not_self'
    add_check_constraint :group_creation_requests, <<~SQL.squish, name: 'group_creation_requests_state_shape'
      (
        state = 0
        AND reviewer_account_id IS NULL
        AND reviewed_at IS NULL
        AND decision_note IS NULL
        AND group_account_id IS NULL
        AND cancelled_at IS NULL
        AND initial_owner_account_id IS NULL
      ) OR (
        state = 1
        AND reviewer_account_id IS NOT NULL
        AND reviewed_at IS NOT NULL
        AND group_account_id IS NOT NULL
        AND cancelled_at IS NULL
        AND initial_owner_account_id IS NOT NULL
      ) OR (
        state = 2
        AND reviewer_account_id IS NOT NULL
        AND reviewed_at IS NOT NULL
        AND decision_note IS NOT NULL
        AND btrim(decision_note) <> ''
        AND group_account_id IS NULL
        AND cancelled_at IS NULL
        AND initial_owner_account_id IS NULL
      ) OR (
        state = 3
        AND reviewer_account_id IS NULL
        AND reviewed_at IS NULL
        AND group_account_id IS NULL
        AND cancelled_at IS NOT NULL
        AND initial_owner_account_id IS NULL
      )
    SQL
  end

  def create_managed_groups
    create_table :managed_groups do |t|
      t.references :account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { unique: true, name: 'index_managed_groups_on_account_id' }
      t.references :creation_request, foreign_key: { to_table: :group_creation_requests, on_delete: :restrict }, index: { unique: true, name: 'index_managed_groups_on_creation_request_id' }
      t.integer :origin, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_check_constraint :managed_groups, <<~SQL.squish, name: 'managed_groups_origin_shape'
      (origin = 0 AND creation_request_id IS NOT NULL)
      OR (origin = 1 AND creation_request_id IS NULL)
    SQL
  end

  def create_group_role_assignments
    create_table :group_role_assignments do |t|
      t.references :group_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_role_assignments_on_group_account_id' }
      t.references :member_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: false
      t.integer :role, null: false
      t.references :granted_by_account, foreign_key: { to_table: :accounts, on_delete: :nullify }, index: { name: 'index_group_role_assignments_on_granted_by_account_id' }
      t.datetime :granted_at, null: false
      t.datetime :revoked_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :group_role_assignments, :group_account_id,
              unique: true,
              where: 'role = 0 AND revoked_at IS NULL',
              name: 'index_group_role_assignments_one_active_owner'
    add_index :group_role_assignments, [:group_account_id, :member_account_id],
              unique: true,
              where: 'revoked_at IS NULL',
              name: 'index_group_role_assignments_one_active_member'
    add_index :group_role_assignments, :member_account_id,
              where: 'revoked_at IS NULL',
              name: 'index_group_role_assignments_on_active_member'

    add_check_constraint :group_role_assignments,
                         'role IN (0, 1)',
                         name: 'group_role_assignments_role_known'
    add_check_constraint :group_role_assignments,
                         'member_account_id <> group_account_id',
                         name: 'group_role_assignments_member_is_not_group'
    add_check_constraint :group_role_assignments,
                         'revoked_at IS NULL OR revoked_at >= granted_at',
                         name: 'group_role_assignments_revocation_order'
  end
end
