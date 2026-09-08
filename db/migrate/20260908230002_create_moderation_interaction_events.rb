# frozen_string_literal: true

class CreateModerationInteractionEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :moderation_interaction_events do |t|
      t.references :actor_subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false
      t.references :target_subject, null: false, foreign_key: { to_table: :moderation_subjects, on_delete: :cascade }, index: false

      t.integer :event_type, null: false

      # Short-term investigation pointers only; intentionally NOT foreign keys so
      # deleting the originating Status/record never removes the observed event.
      t.bigint :status_id
      t.string :source_record_type
      t.bigint :source_record_id
      t.bigint :import_batch_id

      t.datetime :occurred_at, null: false
      t.datetime :observed_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :moderation_interaction_events, [:actor_subject_id, :occurred_at], name: :index_mod_interaction_events_on_actor_and_occurred
    add_index :moderation_interaction_events, [:target_subject_id, :occurred_at], name: :index_mod_interaction_events_on_target_and_occurred
    add_index :moderation_interaction_events, [:actor_subject_id, :target_subject_id, :occurred_at], name: :index_mod_interaction_events_on_actor_target_occurred
    add_index :moderation_interaction_events, [:event_type, :occurred_at], name: :index_mod_interaction_events_on_type_and_occurred
  end
end
