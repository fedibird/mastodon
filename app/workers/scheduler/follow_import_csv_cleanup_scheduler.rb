# frozen_string_literal: true

# Maintains the raw uploaded Import (CSV) for follow imports in two bounded,
# non-destructive-by-inference passes:
#
#   1. Cleanup (dispatch complete) — a batch whose targets have NO pending entries:
#      every follow has been enqueued with its address, so no executor will re-read
#      the CSV. The import is dropped. Age alone does NOT prove abandonment:
#      gate-enforced delay/moderator_review targets are left pending on purpose
#      (PR C) and still need the CSV for a future recheck, so a batch with pending
#      targets is never cleaned here regardless of age. (A durable defer/
#      abandonment lifecycle for those is deferred to a later PR.)
#
#   2. Recovery (stalled handoff) — a follow Import that, after RECOVERY_GRACE,
#      still has NO FollowImportBatch. Its FollowImport::ProcessImportWorker may
#      have been lost, OR the enqueue may have reached Redis and be sitting
#      unprocessed (outage/backlog) — absence of a batch cannot distinguish these,
#      so this pass NEVER deletes the import. It simply RE-ENQUEUES the processor,
#      which is idempotent by import_id (recording returns the existing batch and
#      duplicate executor jobs are DB-claim safe). A genuinely un-runnable import
#      is dropped by the processor's own retries-exhausted hook, not here. True
#      orphan deletion is deferred until a durable abandoned/completed state makes
#      it provably safe.
#
# Bookkeeping/recovery only — batches and target rows persist.
class Scheduler::FollowImportCsvCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT    = 500
  RECOVERY_GRACE = 6.hours

  def perform
    now       = Time.now.utc
    dropped   = 0
    recovered = 0

    batches_with_surviving_import.order(:imported_at).limit(BATCH_LIMIT).each do |batch|
      import = Import.find_by(id: batch.import_id)
      next if import.nil?
      next if batch.targets.where(state: :pending).exists? # dispatch not complete; CSV still needed

      import.destroy
      dropped += 1
    end

    stalled_follow_imports(now).order(:created_at).limit(BATCH_LIMIT).each do |import|
      # Recovery, NOT deletion: re-enqueue the idempotent processor.
      FollowImport::ProcessImportWorker.perform_async(import.id)
      recovered += 1
    end

    Rails.logger.info("[Scheduler::FollowImportCsvCleanupScheduler] dropped=#{dropped} recovered=#{recovered}")
  end

  private

  # Only follow-import batches whose uploaded Import still exists (the INNER JOIN
  # excludes batches whose import was already destroyed, so they are not rescanned).
  def batches_with_surviving_import
    FollowImportBatch.joins('INNER JOIN imports ON imports.id = follow_import_batches.import_id')
  end

  # Follow imports older than the grace window that never got a batch recorded.
  def stalled_follow_imports(now)
    Import.where(type: :following)
          .where('imports.created_at < ?', now - RECOVERY_GRACE)
          .where.not(id: FollowImportBatch.where.not(import_id: nil).select(:import_id))
  end
end
