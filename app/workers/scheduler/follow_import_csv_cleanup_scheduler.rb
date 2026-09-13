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
# The only safe cleanup condition is dispatch completion: drop the CSV once the
# batch has NO pending targets, because at that point every follow has been
# enqueued with its address and no executor will re-read the CSV. Age alone does
# NOT prove abandonment — gate-enforced delay/moderator_review targets are left
# pending on purpose (PR C) and still need the CSV for a future recheck — so a
# batch with pending targets is never cleaned here regardless of age. (Reclaiming
# genuinely abandoned pending targets needs an explicit durable defer/abandonment
# lifecycle, deferred to a later PR.) Bookkeeping only — the batch and its target
# rows persist.
class Scheduler::FollowImportCsvCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT = 500

  def perform
    dropped = 0

    batches_with_surviving_import.order(:imported_at).limit(BATCH_LIMIT).each do |batch|
      import = Import.find_by(id: batch.import_id)
      next if import.nil?
      next if batch.targets.where(state: :pending).exists? # dispatch not complete; CSV still needed

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
end
