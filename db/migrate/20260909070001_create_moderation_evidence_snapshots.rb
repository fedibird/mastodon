# frozen_string_literal: true

class CreateModerationEvidenceSnapshots < ActiveRecord::Migration[6.1]
  def change
    create_table :moderation_evidence_snapshots do |t|
      t.references :subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false

      t.datetime :window_start
      t.datetime :window_end
      t.jsonb :summary, null: false, default: {}
      t.jsonb :fingerprint, null: false, default: {}
      t.integer :schema_version, null: false, default: 1

      t.timestamps
    end

    add_index :moderation_evidence_snapshots, [:subject_id, :created_at], name: :index_mod_evidence_snapshots_on_subject_and_created
  end
end
