# frozen_string_literal: true

class ImportWorker
  include Sidekiq::Worker

  # retry: false is preserved for every import type. Only follow imports need the
  # resilient, retryable handoff (their execution is idempotent); that logic lives
  # entirely in FollowImport::ProcessImportWorker so this worker's retry semantics
  # are NOT changed for the other, not-necessarily-idempotent import types.
  sidekiq_options queue: 'pull', retry: false

  def perform(import_id)
    import = Import.find(import_id)

    return hand_off_follow_import(import) if import.following?

    begin
      ImportService.new.call(import)
    ensure
      import.destroy
    end
  end

  private

  # Follow imports are recorded and handed off to their executor by a dedicated,
  # retryable worker that owns the import's lifecycle (it re-reads the CSV to
  # resolve target addresses/options and destroys the import once dispatch
  # completes), so we do not destroy the import here.
  def hand_off_follow_import(import)
    FollowImport::ProcessImportWorker.perform_async(import.id)
  rescue StandardError => e
    # Could not even enqueue the processor (nothing was recorded and none is
    # queued). Drop the import so its raw CSV does not leak; retry: false keeps the
    # run-once import semantics.
    Rails.logger.warn("[ImportWorker] follow-import handoff enqueue failed: #{e.class}: #{e.message}")
    import.destroy
  end
end
