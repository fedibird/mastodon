# frozen_string_literal: true

class ImportWorker
  include Sidekiq::Worker

  # retry: false is preserved for every import type. Follow imports get their
  # resilient, retryable handoff from FollowImport::ProcessImportWorker (routed to
  # directly at the dispatch point), so this worker's retry semantics are NOT
  # changed for the other, not-necessarily-idempotent import types.
  sidekiq_options queue: 'pull', retry: false

  def perform(import_id)
    import = Import.find(import_id)

    # Follow imports are normally routed straight to the retryable processor at the
    # dispatch point. If one still reaches this worker, hand it off there rather
    # than running the fragile record+handoff inline. NEVER destroy the import on
    # an enqueue exception: an external queue write is ambiguous (Redis may have
    # accepted the job before the client saw the error), so a genuine orphan is
    # reclaimed by the bounded CSV watchdog instead.
    return FollowImport::ProcessImportWorker.perform_async(import.id) if import.following?

    begin
      ImportService.new.call(import)
    ensure
      import.destroy
    end
  end
end
