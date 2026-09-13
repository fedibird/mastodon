# frozen_string_literal: true

# Retryable processor for a follow import: records the batch and hands the follow
# set to the executor. Isolated from ImportWorker (retry: false) so retry
# semantics change ONLY for follow imports — a transient Sidekiq/Redis failure
# while recording or handing off is retried, and reprocessing is idempotent
# (batch recording is keyed on import_id, and duplicate executor jobs are safe
# because execution is DB-claim based). Other import types keep retry: false.
module FollowImport
  class ProcessImportWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'pull', retry: 5, dead: false

    sidekiq_retries_exhausted do |msg|
      import_id = msg['args'].first

      # Conservatively RETAIN the import whenever a batch exists: a
      # BatchExecutionWorker job may already be queued (the handoff can succeed
      # before a later step fails) and the absence of any in-memory marker cannot
      # prove no such job exists — deleting the CSV could leave that executor
      # running without it. A genuinely abandoned import is reclaimed later by the
      # bounded Scheduler::FollowImportCsvCleanupScheduler once dispatch is known
      # complete. Drop the CSV only when no batch owns it.
      Import.find_by(id: import_id)&.destroy unless FollowImportBatch.exists?(import_id: import_id)
    rescue StandardError => e
      Rails.logger.warn("[FollowImport::ProcessImportWorker] retries-exhausted cleanup failed: #{e.class}: #{e.message}")
    end

    def perform(import_id)
      import = Import.find(import_id)
      ImportService.new.call(import)

      # Success: when a batch was recorded the executor owns the import (it destroys
      # it once dispatch completes), so leave it. If recording failed, the direct
      # fallback already enqueued the follows with their addresses, so drop the CSV.
      # On FAILURE the import is deliberately NOT destroyed, so a retry can reprocess.
      import.destroy unless FollowImportBatch.exists?(import_id: import.id)
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
