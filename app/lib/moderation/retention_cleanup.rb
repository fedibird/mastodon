# frozen_string_literal: true

# SQL-only predicates for ledger retention cleanup.
#
# Kept out of Ruby on purpose: loading retained subject ids and interpolating
# them into `NOT IN (...)` does not scale, and `WHERE column NOT IN (...)`
# does not match NULL under SQL three-valued logic. Counterpart FKs are
# ON DELETE SET NULL, so a leftover event may have one or both participants
# already nullified.
#
# An event is deletable when it has no retained participant — each side is
# either NULL or an expired subject. NOT EXISTS treats a NULL FK as "this
# side is not a retained participant", which is the desired eligibility rule.
module Moderation
  module RetentionCleanup
    module_function

    def events_without_retained_participant(klass, left_column, right_column, now)
      conn = klass.connection
      # Rails 6.1 Arel attributes do not implement +to_sql+; quote the
      # identifier pair explicitly so the predicate stays SQL-only.
      left = "#{conn.quote_table_name(klass.table_name)}.#{conn.quote_column_name(left_column)}"
      right = "#{conn.quote_table_name(klass.table_name)}.#{conn.quote_column_name(right_column)}"
      klass.where(
        <<~SQL.squish,
          NOT EXISTS (
            SELECT 1
              FROM moderation_subjects
             WHERE moderation_subjects.id IN (#{left}, #{right})
               AND (moderation_subjects.retention_until IS NULL OR moderation_subjects.retention_until > ?)
          )
        SQL
        now
      )
    end

    # Expired subjects that no remaining event still needs as shared evidence.
    # A subject is held past +retention_until+ while it appears on an event
    # that still has a retained counterpart.
    def expired_subjects_without_retained_evidence(now)
      ModerationSubject.expired(now).where(
        <<~SQL.squish,
          NOT EXISTS (
            SELECT 1
              FROM moderation_interaction_events e
             WHERE (e.actor_subject_id = moderation_subjects.id OR e.target_subject_id = moderation_subjects.id)
               AND EXISTS (
                 SELECT 1
                   FROM moderation_subjects r
                  WHERE r.id IN (e.actor_subject_id, e.target_subject_id)
                    AND (r.retention_until IS NULL OR r.retention_until > ?)
               )
          )
          AND NOT EXISTS (
            SELECT 1
              FROM moderation_rejection_events e
             WHERE (e.rejector_subject_id = moderation_subjects.id OR e.rejected_subject_id = moderation_subjects.id)
               AND EXISTS (
                 SELECT 1
                   FROM moderation_subjects r
                  WHERE r.id IN (e.rejector_subject_id, e.rejected_subject_id)
                    AND (r.retention_until IS NULL OR r.retention_until > ?)
               )
          )
        SQL
        now, now
      )
    end
  end
end
