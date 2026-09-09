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

    expired_ids = ModerationSubject.expired(now).pluck(:id)
    return 0 if expired_ids.empty?
    return expired_ids.size if dry_run?

    delete_events_without_retained_participant!(expired_ids)
    deletable_ids = expired_ids - subject_ids_still_referenced(expired_ids)
    return 0 if deletable_ids.empty?

    ModerationSubject.where(id: deletable_ids).in_batches.delete_all
    deletable_ids.size
  end

  # Drop events whose every participant is expired (or already null). Events
  # that still name a retained subject are left intact.
  def delete_events_without_retained_participant!(expired_ids)
    retained_ids = ModerationSubject.where.not(id: expired_ids).pluck(:id)

    ModerationInteractionEvent.where.not(actor_subject_id: retained_ids).where.not(target_subject_id: retained_ids).in_batches.delete_all
    ModerationRejectionEvent.where.not(rejector_subject_id: retained_ids).where.not(rejected_subject_id: retained_ids).in_batches.delete_all
  end

  def subject_ids_still_referenced(expired_ids)
    (
      ModerationInteractionEvent.where(actor_subject_id: expired_ids).distinct.pluck(:actor_subject_id) +
      ModerationInteractionEvent.where(target_subject_id: expired_ids).distinct.pluck(:target_subject_id) +
      ModerationRejectionEvent.where(rejector_subject_id: expired_ids).distinct.pluck(:rejector_subject_id) +
      ModerationRejectionEvent.where(rejected_subject_id: expired_ids).distinct.pluck(:rejected_subject_id)
    ).compact.uniq
  end

  def dry_run?
    ENV['MODERATION_LEDGER_RETENTION_DRY_RUN'] == 'true'
  end
end
