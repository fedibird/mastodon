# frozen_string_literal: true

# Approval audit rows, a per-group registration-invite snapshot, and the
# durable icon-handoff columns. No backfill: groups that already exist do
# not gain a policy, an owner, or a managed row. Pending usernames stay
# non-unique. See docs/group_management_p2a.md.
#
# The request table already exists. New columns use a constant default, the
# partial index matches only approved rows that still have a private icon,
# and the lock is bounded. A failure rolls the tables, columns, and checks
# back together.
class AddGroupApprovalRecords < ActiveRecord::Migration[6.1]
  HANDOFF_INDEX = 'index_group_creation_requests_on_open_icon_handoff'
  HANDOFF_CHECK = 'group_creation_requests_icon_handoff_shape'
  POLICY_CHECK = 'group_registration_invite_policies_limits'
  DECISION_CHECK = 'group_creation_decisions_shape'

  HANDOFF_SQL = <<~SQL.squish
    icon_handoff_attempts >= 0
    AND (
      icon_handoff_error IS NULL
      OR icon_handoff_error ~ '^[a-z0-9_]{1,64}$'
    )
    AND (
      icon_handoff_source_digest IS NULL
      OR icon_handoff_source_digest ~ '^[0-9a-f]{64}$'
    )
    AND (
      icon_handoff_copied_at IS NULL
      OR (
        state = 1
        AND icon_handoff_source_digest IS NOT NULL
      )
    )
    AND (
      icon_storage_key IS NOT NULL
      OR (
        icon_handoff_copied_at IS NULL
        AND icon_handoff_source_digest IS NULL
        AND icon_handoff_failed_at IS NULL
        AND icon_handoff_error IS NULL
        AND icon_handoff_attempts = 0
      )
    )
  SQL

  POLICY_SQL = <<~SQL.squish
    shared_registration_quota >= 0
    AND (
      (shared_quota_unlimited = TRUE AND shared_registration_quota = 0)
      OR shared_quota_unlimited = FALSE
    )
    AND (
      (per_link_unlimited_uses = TRUE AND per_link_max_uses IS NULL)
      OR (
        per_link_unlimited_uses = FALSE
        AND per_link_max_uses IS NOT NULL
        AND per_link_max_uses >= 1
      )
    )
    AND (
      (per_link_indefinite = TRUE AND per_link_lifetime_seconds IS NULL)
      OR (
        per_link_indefinite = FALSE
        AND per_link_lifetime_seconds IS NOT NULL
        AND per_link_lifetime_seconds >= 1
      )
    )
  SQL

  DECISION_SQL = <<~SQL.squish
    (
      action = 0
      AND group_account_id IS NOT NULL
    )
    OR (
      action = 1
      AND group_account_id IS NULL
      AND decision_note IS NOT NULL
      AND btrim(decision_note) <> ''
    )
  SQL

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      create_policies
      create_decisions
      add_handoff_columns
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      remove_handoff_columns
      drop_table :group_creation_decisions
      drop_table :group_registration_invite_policies
    end
  end

  private

  def create_policies
    create_table :group_registration_invite_policies do |t|
      t.references :managed_group, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true, name: 'index_group_invite_policies_on_managed_group_id' }
      t.references :group_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { unique: true, name: 'index_group_invite_policies_on_group_account_id' }
      t.boolean :issuance_enabled, null: false
      t.integer :shared_registration_quota, null: false
      t.boolean :shared_quota_unlimited, null: false, default: false
      t.integer :per_link_max_uses
      t.boolean :per_link_unlimited_uses, null: false, default: false
      t.integer :per_link_lifetime_seconds
      t.boolean :per_link_indefinite, null: false, default: false
      t.datetime :copied_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :group_registration_invite_policies, POLICY_SQL, name: POLICY_CHECK
  end

  def create_decisions
    create_table :group_creation_decisions do |t|
      t.references :group_creation_request, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true, name: 'index_group_creation_decisions_on_request_id' }
      t.references :reviewer_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_creation_decisions_on_reviewer_account_id' }
      t.references :group_account, foreign_key: { to_table: :accounts, on_delete: :restrict }, index: { name: 'index_group_creation_decisions_on_group_account_id' }
      t.integer :action, null: false
      t.text :decision_note
      t.timestamps
    end
    add_check_constraint :group_creation_decisions, DECISION_SQL, name: DECISION_CHECK
  end

  def add_handoff_columns
    add_column :group_creation_requests, :icon_handoff_copied_at, :datetime
    add_column :group_creation_requests, :icon_handoff_source_digest, :string, limit: 64
    add_column :group_creation_requests, :icon_handoff_attempts, :integer, null: false, default: 0
    add_column :group_creation_requests, :icon_handoff_error, :string, limit: 64
    add_column :group_creation_requests, :icon_handoff_failed_at, :datetime
    add_index :group_creation_requests, :reviewed_at, where: 'state = 1 AND icon_storage_key IS NOT NULL AND icon_purged_at IS NULL', name: HANDOFF_INDEX
    add_check_constraint :group_creation_requests, HANDOFF_SQL, name: HANDOFF_CHECK
  end

  def remove_handoff_columns
    remove_check_constraint :group_creation_requests, name: HANDOFF_CHECK
    remove_index :group_creation_requests, name: HANDOFF_INDEX
    remove_column :group_creation_requests, :icon_handoff_failed_at
    remove_column :group_creation_requests, :icon_handoff_error
    remove_column :group_creation_requests, :icon_handoff_attempts
    remove_column :group_creation_requests, :icon_handoff_source_digest
    remove_column :group_creation_requests, :icon_handoff_copied_at
  end
end
