# frozen_string_literal: true

# Shared ledger events must survive expiry of one participant. Counterpart
# subject FKs become nullable and SET NULL so deleting a subject never
# cascade-destroys evidence still needed by a retained counterpart.
#
# Irreversible: after this runs, ON DELETE SET NULL (and cleanup) may leave
# NULL participant ids. Restoring NOT NULL / ON DELETE CASCADE would fail on
# those rows or silently destroy shared evidence. Do not implement a down
# path that deletes NULL-participant events to force the restore.
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
    raise ActiveRecord::IrreversibleMigration, <<~MSG.squish
      Cannot restore NOT NULL / ON DELETE CASCADE on moderation event subject
      FKs: existing rows may have NULL participant ids (SET NULL after a
      counterpart delete, or leftover events). Forcing NOT NULL would fail;
      deleting those rows would destroy shared evidence.
    MSG
  end
end
