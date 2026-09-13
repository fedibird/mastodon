# frozen_string_literal: true

# Sweeps follow-import targets whose Accept/Reject response window has elapsed
# and marks them completed_no_response. This is purely execution-state
# bookkeeping: no follow is retried, reversed, or acted on, and nothing is
# written to the moderation ledger.
#
# State lives in the database, so the sweep is naturally durable across restarts
# — each run re-queries the overdue set. Each target is transitioned through the
# row-locked, idempotent TargetTransitionService, so a concurrent inbound
# Accept/Reject that reaches accepted/rejected first wins (those are terminal and
# the sweep's transition is then refused). A bounded number is processed per run;
# any remainder is drained on the next scheduled pass.
class Scheduler::FollowImportResponseTimeoutScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_SIZE = 1_000

  def perform
    now         = Time.now.utc
    transitions = FollowImport::TargetTransitionService.new
    swept       = 0

    FollowImportTarget.response_overdue(now).order(:response_deadline_at).limit(BATCH_SIZE).each do |target|
      transitions.mark_completed_no_response(target, at: now)
      swept += 1
    end

    Rails.logger.info("[Scheduler::FollowImportResponseTimeoutScheduler] swept=#{swept}")
  end
end
