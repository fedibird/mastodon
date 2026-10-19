# frozen_string_literal: true

class Scheduler::ExternalBridgeRSSRefreshScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  BATCH = 20

  def perform
    return unless ExternalBridge::Feature.enabled?

    tester_ids = ExternalBridge::Feature.tester_ids
    return if tester_ids.empty?

    cutoff = ExternalBridge::RSS::Limits::FRESH_FOR.ago
    ids = ExternalSource.joins(:external_subscriptions)
                        .merge(ExternalSubscription.active.where(user_id: tester_ids))
                        .where('external_subscriptions.checked_at IS NULL OR external_subscriptions.checked_at < ?', cutoff)
                        .distinct
                        .limit(BATCH)
                        .pluck('external_sources.id')
    ids.each { |id| ExternalBridge::RSS::RefreshSourceWorker.perform_async(id) }
  end
end
