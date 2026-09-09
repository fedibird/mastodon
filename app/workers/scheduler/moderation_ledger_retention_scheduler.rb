# frozen_string_literal: true

# Retention cleanup for the moderation ledger.
#
#   1. Reconcile orphans: subjects detached from their account (account_id
#      nullified by the FK on account deletion) that were never tombstoned — for
#      example when deletion happened through a path that bypassed the service
#      hook. They are tombstoned so the retention window starts.
#   2. Expire: tombstoned subjects past their retention_until are deleted; the
#      database foreign keys cascade to their recorded events.
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

    scope = ModerationSubject.expired(now)
    count = scope.count
    return count if count.zero? || dry_run?

    # delete_all relies on ON DELETE CASCADE to remove the subject's events.
    scope.in_batches.delete_all
    count
  end

  def dry_run?
    ENV['MODERATION_LEDGER_RETENTION_DRY_RUN'] == 'true'
  end
end
