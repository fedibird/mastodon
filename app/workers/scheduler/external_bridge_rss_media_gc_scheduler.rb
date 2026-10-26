# frozen_string_literal: true

# Picks up external media GC plans whose process died after the purge
# committed, and drops resolved plans after the retention window. Not gated
# by ExternalBridge flags. Does not delete a MediaAttachment that has no
# intent, including ordinary compose uploads.
class Scheduler::ExternalBridgeRSSMediaGcScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  def perform
    report = ExternalBridge::MediaGc.diagnose(sample: 0)
    pruned = ExternalBridge::MediaGc.prune_resolved!
    kicked = false
    if report[:due].positive?
      ExternalBridge::RSS::MediaGcWorker.perform_async
      kicked = true
    end
    Rails.logger.info(
      "[Scheduler::ExternalBridgeRSSMediaGcScheduler] pending=#{report[:pending]} due=#{report[:due]} " \
      "failed=#{report[:failed]} retained=#{report[:retained]} released=#{report[:released]} " \
      "pruned=#{pruned} kicked=#{kicked}"
    )
    report[:due]
  end
end
