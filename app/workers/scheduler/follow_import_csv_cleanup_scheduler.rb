# frozen_string_literal: true

# Bounded watchdog that drops the raw uploaded Import (its CSV) for follow-import
# batches once it is no longer needed — a safety net for imports the executor did
# not finalize itself.
#
# Normally FollowImport::BatchExecutionWorker destroys the import the moment it
# finishes dispatch. But the import can survive when the executor crashed after
# dispatch but before finalizing, or when the executor handoff ultimately failed
# so no executor job will ever run (ImportWorker's retries-exhausted path
# conservatively RETAINS any import that has a batch, because it cannot prove no
# executor job is queued). This reclaims those.
#
# Reclaims the raw uploaded Import (CSV) for follow imports once it is safe, in
# two bounded, non-destructive-by-age passes:
#
#   1. Dispatch complete — a batch whose targets have NO pending entries: every
#      follow has been enqueued with its address, so no executor will re-read the
#      CSV. Age alone does NOT prove abandonment: gate-enforced delay/
#      moderator_review targets are left pending on purpose (PR C) and still need
#      the CSV for a future recheck, so a batch with pending targets is never
#      cleaned here regardless of age. (A durable defer/abandonment lifecycle for
#      those is deferred to a later PR.)
#
#   2. Orphaned handoff — a follow Import that, after ORPHAN_GRACE, still has NO
#      FollowImportBatch. Its ProcessImportWorker enqueue was genuinely lost: an
#      ambiguous enqueue that actually reached Redis would, by now, have recorded
#      a batch (moving it to pass 1) or been dropped by the processor's
#      retries-exhausted hook. The grace resolves that ambiguity by waiting.
#
# Bookkeeping only — batches and target rows persist.
class Scheduler::FollowImportCsvCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT   = 500
  ORPHAN_GRACE  = 6.hours

  def perform
    now     = Time.now.utc
    dropped = 0

    batches_with_surviving_import.order(:imported_at).limit(BATCH_LIMIT).each do |batch|
      import = Import.find_by(id: batch.import_id)
      next if import.nil?
      next if batch.targets.where(state: :pending).exists? # dispatch not complete; CSV still needed

      import.destroy
      dropped += 1
    end

    orphaned_follow_imports(now).order(:created_at).limit(BATCH_LIMIT).each do |import|
      import.destroy
      dropped += 1
    end

    Rails.logger.info("[Scheduler::FollowImportCsvCleanupScheduler] dropped=#{dropped}")
  end

  private

  # Only follow-import batches whose uploaded Import still exists (the INNER JOIN
  # excludes batches whose import was already destroyed, so they are not rescanned).
  def batches_with_surviving_import
    FollowImportBatch.joins('INNER JOIN imports ON imports.id = follow_import_batches.import_id')
  end

  # Follow imports older than the grace window that never got a batch recorded.
  def orphaned_follow_imports(now)
    Import.where(type: :following)
          .where('imports.created_at < ?', now - ORPHAN_GRACE)
          .where.not(id: FollowImportBatch.where.not(import_id: nil).select(:import_id))
  end
end
