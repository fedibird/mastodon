# frozen_string_literal: true

class CreateModerationRejectionEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :moderation_rejection_events do |t|
      t.references :rejector_subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false
      t.references :rejected_subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false

      t.integer :event_type, null: false

      # Optional link to the interaction that immediately preceded the rejection.
      # ON DELETE SET NULL so pruning an interaction never drops the rejection.
      t.bigint :preceding_interaction_event_id

      t.datetime :occurred_at, null: false
      t.datetime :observed_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    safety_assured do
      add_foreign_key :moderation_rejection_events, :moderation_interaction_events, column: :preceding_interaction_event_id, on_delete: :nullify
    end

    add_index :moderation_rejection_events, [:rejected_subject_id, :occurred_at], name: :index_mod_rejection_events_on_rejected_and_occurred
    add_index :moderation_rejection_events, [:rejector_subject_id, :occurred_at], name: :index_mod_rejection_events_on_rejector_and_occurred
    add_index :moderation_rejection_events, [:rejected_subject_id, :rejector_subject_id, :occurred_at], name: :index_mod_rejection_events_on_rejected_rejector_occurred
    add_index :moderation_rejection_events, [:event_type, :occurred_at], name: :index_mod_rejection_events_on_type_and_occurred
    add_index :moderation_rejection_events, :preceding_interaction_event_id, where: 'preceding_interaction_event_id IS NOT NULL', name: :index_mod_rejection_events_on_preceding_event
  end
end
