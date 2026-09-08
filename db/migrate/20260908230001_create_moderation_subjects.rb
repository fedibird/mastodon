# frozen_string_literal: true

class CreateModerationSubjects < ActiveRecord::Migration[6.1]
  def change
    create_table :moderation_subjects do |t|
      # Deliberately ON DELETE SET NULL (never cascade): a subject and its
      # recorded events must outlive the underlying Account per the retention
      # policy, so account deletion/purge only detaches the link.
      t.references :account, foreign_key: { on_delete: :nullify }, index: false

      t.integer :origin, null: false, default: 0
      t.string :domain
      t.string :actor_uri_hash

      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :deleted_at
      t.datetime :retention_until

      t.timestamps
    end

    add_index :moderation_subjects, :account_id, unique: true, where: 'account_id IS NOT NULL', name: :index_moderation_subjects_on_account_id
    add_index :moderation_subjects, :actor_uri_hash, where: 'actor_uri_hash IS NOT NULL', name: :index_moderation_subjects_on_actor_uri_hash
    add_index :moderation_subjects, :retention_until, name: :index_moderation_subjects_on_retention_until
    add_index :moderation_subjects, :deleted_at, name: :index_moderation_subjects_on_deleted_at
  end
end
