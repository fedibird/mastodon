# frozen_string_literal: true

# Backfills the shared icon of sources that predate the icon feature and
# re-checks stored icons when their weekly validation or retry backoff is due.
# One pass queues at most BATCH sources. The refresh itself decides whether a
# download is needed, so a source that is not due is never fetched.
class Scheduler::ExternalBridgeRSSIconScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  BATCH = 20

  def perform
    return unless ExternalBridge::Feature.enabled?

    tester_ids = ExternalBridge::Feature.tester_ids
    return if tester_ids.empty?

    subscribed = ExternalSubscription.active.where(user_id: tester_ids).select(:external_source_id)
    due = 'external_sources.icon_next_check_at IS NULL OR external_sources.icon_next_check_at <= :now'
    ids = ExternalSource.where(id: subscribed)
                        .where.not(fetched_at: nil)
                        .where(due, now: Time.current)
                        .order(Arel.sql('external_sources.icon_next_check_at ASC NULLS FIRST'), :id)
                        .limit(BATCH)
                        .pluck(:id)

    ids.each { |id| ExternalBridge::RSS::IconRefreshWorker.perform_async(id) }
  end
end
