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
# Both cleanup conditions are safe: drop the CSV when the batch has no pending
# targets (dispatch is complete, so no executor needs it), or when the batch is
# older than ABANDON_AFTER (the executor is definitively not coming). A batch
# that is still mid-dispatch (recent and with pending targets) is left alone.
# Notification/bookkeeping only — the batch and its target rows persist.
class Scheduler::FollowImportCsvCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT   = 500
  ABANDON_AFTER = 7.days

  def perform
    now     = Time.now.utc
    dropped = 0

    batches_with_surviving_import.order(:imported_at).limit(BATCH_LIMIT).each do |batch|
      import = Import.find_by(id: batch.import_id)
      next if import.nil?
      next unless batch.targets.where(state: :pending).none? || batch.imported_at < now - ABANDON_AFTER

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
