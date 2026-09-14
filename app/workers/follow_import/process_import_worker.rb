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
      # Intentionally non-destructive. Absence of a FollowImportBatch cannot
      # prove absence of another queued/retrying ProcessImportWorker: the
      # watchdog recovery path (and ambiguous enqueues) can leave multiple
      # retry chains for the same import_id before a batch is recorded. One
      # chain exhausting must not delete the CSV a sibling still needs.
      # True deletion waits for an explicit durable abandoned/failed state.
      Rails.logger.info("[FollowImport::ProcessImportWorker] retries exhausted for import #{msg['args'].first}; retaining CSV")
    end

    def perform(import_id)
      import = Import.find(import_id)

      # Defense in depth: only the current supported pipeline version may reach
      # ImportService. NULL leftover rows and unknown versions fail closed even
      # if a leftover Sidekiq job still names their id. Do not delete them here
      # — leftover cleanup is an operator maintenance task only.
      if import.following? && !import.follow_import_recovery_aware?
        Rails.logger.warn("[FollowImport::ProcessImportWorker] refusing follow import #{import.id} (pipeline_version=#{import.follow_import_pipeline_version.inspect}); skipping ImportService")
        return
      end

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
