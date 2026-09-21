# frozen_string_literal: true

require 'csv'

# Replays the post-approval Follow Import handoff.
#
# At-least-once, not exactly-once. A crash after Sidekiq enqueues and
# before review_resume_completed_at is persisted leaves the marker
# pending so this worker, or
# Scheduler::FollowImportActionReviewResumeScheduler, can replay.
# RelationshipWorker and BatchExecutionWorker claim paths tolerate
# that replay. Approval is permission to run this import, not an
# account trust verdict. Scheduler-owned batches stay on the
# scheduler and are not converted to the legacy worker.
module FollowImport
  class ActionReviewResumeWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'pull', retry: 5, dead: false

    def perform(request_id)
      request = ActionReviewRequest.find_by(id: request_id)
      return if request.nil?
      return unless request.operation_type == 'follow_import'
      return unless request.approved_state?

      batch = request.resource
      return unless batch.is_a?(FollowImportBatch)
      return if batch.review_resume_completed?
      raise_retry('batch is not ready') unless batch.ready_preflight_state?

      import = Import.find_by(id: batch.import_id)
      raise_retry('follow import csv is missing') if import.nil?

      handoff!(batch, import)
      batch.mark_review_resume_completed!
    end

    private

    def raise_retry(message)
      raise message
    end

    def handoff!(batch, import)
      enqueue_legacy_executor!(batch)
      enqueue_overwrite_removals!(batch, import)
    end

    def enqueue_legacy_executor!(batch)
      return if batch.scheduler_dispatch_owner?
      return if batch.historical_dispatch_cohort?

      BatchExecutionWorker.perform_async(batch.id)
    end

    def enqueue_overwrite_removals!(batch, import)
      return unless batch.overwrite_mode?

      account = batch.for_account
      raise_retry('follow import account is missing') if account.nil?

      OverwriteRemovalEnqueue.new.call(account: account, csv_rows: csv_rows(import))
    end

    def csv_rows(import)
      raw = Paperclip.io_adapters.for(import.data).read
      data = CSV.parse(raw, headers: true)
      data = CSV.parse(raw, headers: ['Account address']) unless data.headers&.first&.strip&.include?(' ')
      data.reject(&:blank?).take(ImportService::ROWS_PROCESSING_LIMIT)
    end
  end
end
