# frozen_string_literal: true

# Backstop for approved Follow Imports whose resume handoff was not
# marked complete. The immediate enqueue after approval can be lost;
# this pass re-enqueues FollowImport::ActionReviewResumeWorker. It
# does not decide policy and does not convert scheduler-owned batches
# to the legacy worker. Bounded so it does not scan every historical
# request.
class Scheduler::FollowImportActionReviewResumeScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT = 500

  def perform
    unfinished_requests.limit(BATCH_LIMIT).each do |request|
      FollowImport::ActionReviewResumeWorker.perform_async(request.id)
    end
  end

  private

  def unfinished_requests
    ready = FollowImportBatch.preflight_states[:ready]
    ActionReviewRequest
      .approved_state
      .where(operation_type: 'follow_import', resource_type: 'FollowImportBatch')
      .joins('INNER JOIN follow_import_batches ON follow_import_batches.id = action_review_requests.resource_id')
      .joins('INNER JOIN imports ON imports.id = follow_import_batches.import_id')
      .where(follow_import_batches: { preflight_state: ready })
      .where("(follow_import_batches.metadata ->> 'review_resume_required_at') IS NOT NULL")
      .where("(follow_import_batches.metadata ->> 'review_resume_completed_at') IS NULL")
      .order('action_review_requests.id ASC')
  end
end
