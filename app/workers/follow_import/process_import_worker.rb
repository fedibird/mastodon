# frozen_string_literal: true

# Retryable processor for a follow import: records the batch and hands the
# follow set to its stored dispatch owner (legacy BatchExecutionWorker or
# the periodic global scheduler). Isolated from ImportWorker (retry: false)
# so retry semantics change ONLY for follow imports — a transient failure
# while recording or handing off is retried, and reprocessing is idempotent
# (batch recording is keyed on import_id; stored dispatch_owner is not
# rewritten). Other import types keep retry: false.
#
# When FOLLOW_IMPORT_DISPATCH_GLOBAL is on, a recording failure raises
# instead of falling back to a direct RelationshipWorker bulk enqueue.
# This worker retries; the Import/CSV is retained. The direct follow
# fallback remains only for legacy-mode recording failure.
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

      # Success: when a batch was recorded the stored owner still needs the
      # CSV while pending targets remain, so leave it. If legacy recording
      # failed, the direct fallback already enqueued the follows, so drop
      # the CSV. GLOBAL recording failure raises before this line, so the
      # Import is retained for retry. On FAILURE the import is deliberately
      # NOT destroyed.
      import.destroy unless FollowImportBatch.exists?(import_id: import.id)
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
