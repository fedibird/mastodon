# frozen_string_literal: true

class ImportWorker
  include Sidekiq::Worker

  # Retryable so a transient failure — e.g. Sidekiq/Redis briefly unavailable when
  # handing a follow import off to its executor — is retried rather than leaving
  # the import stranded. Reprocessing is idempotent: follow-import batch recording
  # is keyed on import_id (returns the existing batch), and a duplicate executor
  # job is safe because execution is DB-claim based.
  sidekiq_options queue: 'pull', retry: 5, dead: false

  sidekiq_retries_exhausted do |msg|
    # Terminal failure after all retries — drop the uploaded import so its raw CSV
    # does not leak. Any FollowImportBatch/target rows persist as the record.
    Import.find_by(id: msg['args'].first)&.destroy
  rescue StandardError => e
    Rails.logger.warn("[ImportWorker] retries-exhausted cleanup failed: #{e.class}: #{e.message}")
  end

  def perform(import_id)
    import = Import.find(import_id)
    ImportService.new.call(import)

    # Success. A follow import is executed asynchronously by
    # FollowImport::BatchExecutionWorker, which re-reads the CSV to recover each
    # target's address/options and owns the import — it destroys it once dispatch
    # completes. Everything else (and a follow import whose batch recording failed,
    # which is fully enqueued inline) is dropped here. On FAILURE the import is
    # deliberately NOT destroyed, so a retry can reprocess it.
    import.destroy unless import.following? && FollowImportBatch.exists?(import_id: import.id)
  rescue ActiveRecord::RecordNotFound
    true
  end
end
