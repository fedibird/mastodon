# frozen_string_literal: true

class ImportWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: false

  def perform(import_id)
    import = Import.find(import_id)
    ImportService.new.call(import)
  ensure
    # A follow import is executed asynchronously in bounded passes that re-read
    # the uploaded CSV to recover each target's address and follow options; that
    # executor (FollowImport::BatchExecutionWorker) owns the import and destroys
    # it once dispatch completes. Destroying it here would pull the CSV out from
    # under the executor before any follow runs. Every other import (and a follow
    # import whose batch recording failed, which falls back to a direct enqueue
    # carrying the addresses in the jobs) is fully enqueued inline, so it is
    # destroyed here as before.
    import&.destroy unless import&.following? && FollowImportBatch.exists?(import_id: import.id)
  end
end
