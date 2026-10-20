# frozen_string_literal: true

class Scheduler::ExternalBridgeRSSRefreshScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  BATCH = 20

  def perform
    return unless ExternalBridge::Feature.enabled?

    tester_ids = ExternalBridge::Feature.tester_ids
    return if tester_ids.empty?

    # A source is queued when at least one allowed subscription is due.
    # RefreshSource accounts retry state only for those due rows.
    ids = ExternalSource.joins(:external_subscriptions)
                        .merge(ExternalSubscription.active.due_for_refresh.where(user_id: tester_ids))
                        .distinct
                        .limit(BATCH)
                        .pluck('external_sources.id')
    ids.each { |id| ExternalBridge::RSS::RefreshSourceWorker.perform_async(id) }
  end
end
