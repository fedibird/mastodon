# frozen_string_literal: true

# Retention cleanup for the moderation ledger.
#
#   1. Reconcile orphans: subjects detached from their account (account_id
#      nullified by the FK on account deletion) that were never tombstoned — for
#      example when deletion happened through a path that bypassed the service
#      hook. They are tombstoned so the retention window starts.
#   2. Expire at the *event* level: a shared interaction/rejection is kept as
#      long as any involved subject is still retained. An expired subject is
#      deleted only when no remaining event references it (held otherwise so
#      a retained counterpart's evidence stays internally consistent).
#
# +retention_until+ / MODERATION_LEDGER_RETENTION_DAYS is the earliest
# eligibility time for a tombstoned subject — not a hard deletion deadline.
# An expired subject (and the events it shares) may be held past that date
# while a retained counterpart still needs the row.
#
# Evaluation stays in SQL (EXISTS / IN subqueries). Retained subject ids are
# never loaded into Ruby. NULL participant FKs (ON DELETE SET NULL) are
# treated as "not retained", so an event becomes deletable once every
# remaining participant is expired or null.
#
# Counterpart subject FKs are ON DELETE SET NULL as a safety net; this
# scheduler should not need that path when it holds referenced subjects.
#
# Set MODERATION_LEDGER_RETENTION_DRY_RUN=true to log what would happen without
# modifying any data.
class Scheduler::ModerationLedgerRetentionScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    now = Time.now.utc

    reconciled = reconcile_orphans!(now)
    expired    = expire_tombstoned!(now)

    Rails.logger.info("[Scheduler::ModerationLedgerRetentionScheduler] reconciled=#{reconciled} expired=#{expired} dry_run=#{dry_run?} retention_days=#{Moderation::RetentionPolicy.retention_days}")
  end

  private

  def reconcile_orphans!(now)
    scope = ModerationSubject.orphaned
    count = scope.count
    return count if count.zero? || dry_run?

    scope.in_batches.update_all(deleted_at: now, retention_until: Moderation::RetentionPolicy.expire_at(now))
    count
  end

  def expire_tombstoned!(now)
    return 0 unless Moderation::RetentionPolicy.enabled?

    deletable_subjects = Moderation::RetentionCleanup.expired_subjects_without_retained_evidence(now)
    return deletable_subjects.count if dry_run?

    delete_events_without_retained_participant!(now)

    count = deletable_subjects.count
    return 0 if count.zero?

    deletable_subjects.in_batches.delete_all
    count
  end

  def delete_events_without_retained_participant!(now)
    Moderation::RetentionCleanup
      .events_without_retained_participant(ModerationInteractionEvent, :actor_subject_id, :target_subject_id, now)
      .in_batches.delete_all
    Moderation::RetentionCleanup
      .events_without_retained_participant(ModerationRejectionEvent, :rejector_subject_id, :rejected_subject_id, now)
      .in_batches.delete_all
  end

  def dry_run?
    ENV['MODERATION_LEDGER_RETENTION_DRY_RUN'] == 'true'
  end
end
