# frozen_string_literal: true

# Shared ledger events must survive expiry of one participant. Counterpart
# subject FKs become nullable and SET NULL so deleting a subject never
# cascade-destroys evidence still needed by a retained counterpart.
class NullifyModerationEventSubjectFks < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      remove_foreign_key :moderation_interaction_events, column: :actor_subject_id
      remove_foreign_key :moderation_interaction_events, column: :target_subject_id
      remove_foreign_key :moderation_rejection_events, column: :rejector_subject_id
      remove_foreign_key :moderation_rejection_events, column: :rejected_subject_id

      change_column_null :moderation_interaction_events, :actor_subject_id, true
      change_column_null :moderation_interaction_events, :target_subject_id, true
      change_column_null :moderation_rejection_events, :rejector_subject_id, true
      change_column_null :moderation_rejection_events, :rejected_subject_id, true

      add_foreign_key :moderation_interaction_events, :moderation_subjects, column: :actor_subject_id, on_delete: :nullify
      add_foreign_key :moderation_interaction_events, :moderation_subjects, column: :target_subject_id, on_delete: :nullify
      add_foreign_key :moderation_rejection_events, :moderation_subjects, column: :rejector_subject_id, on_delete: :nullify
      add_foreign_key :moderation_rejection_events, :moderation_subjects, column: :rejected_subject_id, on_delete: :nullify
    end
  end

  def down
    safety_assured do
      remove_foreign_key :moderation_interaction_events, column: :actor_subject_id
      remove_foreign_key :moderation_interaction_events, column: :target_subject_id
      remove_foreign_key :moderation_rejection_events, column: :rejector_subject_id
      remove_foreign_key :moderation_rejection_events, column: :rejected_subject_id

      change_column_null :moderation_interaction_events, :actor_subject_id, false
      change_column_null :moderation_interaction_events, :target_subject_id, false
      change_column_null :moderation_rejection_events, :rejector_subject_id, false
      change_column_null :moderation_rejection_events, :rejected_subject_id, false

      add_foreign_key :moderation_interaction_events, :moderation_subjects, column: :actor_subject_id, on_delete: :cascade
      add_foreign_key :moderation_interaction_events, :moderation_subjects, column: :target_subject_id, on_delete: :cascade
      add_foreign_key :moderation_rejection_events, :moderation_subjects, column: :rejector_subject_id, on_delete: :cascade
      add_foreign_key :moderation_rejection_events, :moderation_subjects, column: :rejected_subject_id, on_delete: :cascade
    end
  end
end
