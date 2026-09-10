# frozen_string_literal: true

class CreateFollowImportBatches < ActiveRecord::Migration[6.1]
  def change
    create_table :follow_import_batches do |t|
      t.references :subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false

      # fedibird destroys the Import row after processing, so this is a plain
      # (non-FK) short-term correlation id, not a foreign key.
      t.bigint :import_id

      t.datetime :imported_at, null: false
      t.integer :mode, null: false, default: 0
      t.integer :target_count, null: false, default: 0
      t.integer :resolved_target_count, null: false, default: 0
      t.integer :unresolved_target_count, null: false, default: 0
      t.bigint :account_age_seconds
      t.integer :migration_evidence, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :follow_import_batches, [:subject_id, :imported_at], name: :index_follow_import_batches_on_subject_and_imported_at
  end
end
