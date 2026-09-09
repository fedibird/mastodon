# frozen_string_literal: true

class CreateFollowImportTargets < ActiveRecord::Migration[6.1]
  def change
    create_table :follow_import_targets do |t|
      t.references :batch, null: false, foreign_key: { to_table: :follow_import_batches, on_delete: :cascade }, index: false

      # Nullable: an imported target may not resolve to a known account at
      # import time. ON DELETE SET NULL keeps the target row if the subject is
      # later removed.
      t.references :target_subject, foreign_key: { to_table: :moderation_subjects, on_delete: :nullify }, index: false

      t.string :target_key_hash
      t.integer :position
      t.jsonb :prior_relationship_state

      t.timestamps
    end

    add_index :follow_import_targets, [:batch_id, :target_subject_id], name: :index_follow_import_targets_on_batch_and_target
    add_index :follow_import_targets, :target_subject_id, where: 'target_subject_id IS NOT NULL', name: :index_follow_import_targets_on_target_subject
    add_index :follow_import_targets, :target_key_hash, where: 'target_key_hash IS NOT NULL', name: :index_follow_import_targets_on_target_key_hash
  end
end
