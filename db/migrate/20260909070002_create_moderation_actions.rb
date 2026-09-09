# frozen_string_literal: true

class CreateModerationActions < ActiveRecord::Migration[6.1]
  def change
    create_table :moderation_actions do |t|
      t.references :subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false

      t.integer :action_type, null: false
      t.datetime :performed_at, null: false

      # ON DELETE SET NULL so a moderator's account deletion never removes the
      # audit of actions they performed.
      t.bigint :moderator_account_id
      t.string :reason_code

      t.references :evidence_snapshot, foreign_key: { to_table: :moderation_evidence_snapshots, on_delete: :nullify }, index: false

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    safety_assured do
      add_foreign_key :moderation_actions, :accounts, column: :moderator_account_id, on_delete: :nullify
    end

    add_index :moderation_actions, [:subject_id, :performed_at], name: :index_moderation_actions_on_subject_and_performed
    add_index :moderation_actions, [:action_type, :performed_at], name: :index_moderation_actions_on_type_and_performed
    add_index :moderation_actions, :evidence_snapshot_id, where: 'evidence_snapshot_id IS NOT NULL', name: :index_moderation_actions_on_evidence_snapshot
    add_index :moderation_actions, :moderator_account_id, where: 'moderator_account_id IS NOT NULL', name: :index_moderation_actions_on_moderator
  end
end
