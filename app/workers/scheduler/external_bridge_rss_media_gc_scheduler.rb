# frozen_string_literal: true

# Picks up external media GC plans whose process died after the purge
# committed, and expired repoint stages whose projection will not be
# visited again. Drops resolved plans after the retention window. Not gated
# by ExternalBridge flags. Does not delete a MediaAttachment that has no
# intent and no stage, including ordinary compose uploads.
class Scheduler::ExternalBridgeRSSMediaGcScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  def perform
    report = ExternalBridge::MediaGc.diagnose(sample: 0)
    pruned = ExternalBridge::MediaGc.prune_resolved!
    due = report[:due].to_i + report[:rechecks_due].to_i
    stages = ExternalBridge::RSS::Media::PreparedRelease.recovery_counts
    stages_waiting = stages[:due] + stages[:exhausted]
    kicked = false
    if due.positive? || stages_waiting.positive?
      ExternalBridge::RSS::MediaGcWorker.perform_async
      kicked = true
    end
    Rails.logger.info(
      "[Scheduler::ExternalBridgeRSSMediaGcScheduler] pending=#{report[:pending]} due=#{report[:due]} " \
      "rechecks_due=#{report[:rechecks_due]} stages_due=#{stages[:due]} stages_exhausted=#{stages[:exhausted]} " \
      "stages_retained=#{stages[:retained]} stages_claim_expired=#{stages[:claim_expired]} " \
      "failed=#{report[:failed]} retained=#{report[:retained]} released=#{report[:released]} " \
      "pruned=#{pruned} kicked=#{kicked}"
    )
    due
  end
end
