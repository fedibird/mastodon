# frozen_string_literal: true

# Notifies importers when their follow-import batch has finished processing.
#
# Completion is detected from the target rows (the source of truth), not from the
# Sidekiq queue or Import lifetime: a batch is done when every target has reached
# a terminal state. A follow Import with no FollowImportBatch is still preparing
# (processor retries / watchdog recovery) and is never treated as complete.
# Because completion can arrive via delivery tracking, inbound Accept/Reject, or
# the response-timeout sweep — none of which is a single choke point — this runs
# periodically, finds not-yet-notified batches that have a durable/recent
# completion signal (persisted completed_at, or all targets terminal with a
# recent last-target completion — never imported_at), emails the importer a
# summary, and records that it notified so the batch is not considered again.
#
# Bookkeeping/notification only: it never changes execution or the ledger.
class Scheduler::FollowImportCompletionScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT = 500
  # Discovery window for not-yet-persisted settlement (MAX target completed_at),
  # not import age. Persisted completed_at stays eligible with no time bound.
  LOOKBACK    = 30.days

  def perform
    now      = Time.now.utc
    progress = FollowImport::ProgressService.new
    notified = 0

    FollowImportBatch.awaiting_completion_notification(now - LOOKBACK).order(:imported_at).limit(BATCH_LIMIT).each do |batch|
      next unless progress.call(batch)['completed']

      batch.record_completion!(now) unless batch.completion_recorded?
      notify_completion(batch, progress)
      notified += 1
    end

    Rails.logger.info("[Scheduler::FollowImportCompletionScheduler] notified=#{notified}")
  end

  private

  def notify_completion(batch, progress)
    account = batch.for_account
    user    = account&.user

    UserMailer.follow_import_finished(user, batch, progress.user_summary(batch)).deliver_later if user

    # Mark regardless (even with no addressable user) so the batch is not rescanned.
    batch.mark_completion_notified!
  rescue StandardError => e
    Rails.logger.warn("[Scheduler::FollowImportCompletionScheduler] failed to notify batch #{batch.id}: #{e.class}: #{e.message}")
  end
end
