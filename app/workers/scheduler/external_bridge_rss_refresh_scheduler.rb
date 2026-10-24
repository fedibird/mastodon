# frozen_string_literal: true

class Scheduler::ExternalBridgeRSSRefreshScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 30.minutes.to_i

  BATCH = 20

  def perform
    started = ExternalBridge::RSS::RefreshLog.now
    stats = { selected: 0, enqueued: 0, rejected: 0, source_ids: [] }

    return log(started, 'feature_disabled', stats) unless ExternalBridge::Feature.enabled?

    tester_ids = ExternalBridge::Feature.tester_ids
    return log(started, 'no_testers', stats) if tester_ids.empty?

    # A source is queued when at least one allowed subscription is due.
    # RefreshSource accounts retry state only for those due rows.
    ids = ExternalSource.joins(:external_subscriptions)
                        .merge(ExternalSubscription.active.due_for_refresh.where(user_id: tester_ids))
                        .distinct
                        .limit(BATCH)
                        .pluck('external_sources.id')
    stats[:selected] = ids.size
    stats[:source_ids] = ids
    return log(started, 'no_due_sources', stats) if ids.empty?

    ids.each do |id|
      # A nil job id means the push was declined (for example an identical job
      # already holds its unique lock). It is not an error.
      jid = ExternalBridge::RSS::RefreshSourceWorker.perform_async(id)
      stats[jid.present? ? :enqueued : :rejected] += 1
    end
    log(started, stats[:enqueued].positive? ? 'queued' : 'not_enqueued', stats)
  rescue StandardError => e
    log(started, 'scheduler_error', stats, error_class: e.class.name)
    raise
  end

  private

  def log(started, outcome, stats, extra = {})
    ExternalBridge::RSS::RefreshLog.emit(
      'scheduler',
      {
        outcome: outcome,
        selected: stats[:selected],
        enqueued: stats[:enqueued],
        rejected: stats[:rejected],
        source_ids: stats[:source_ids],
        elapsed_ms: ExternalBridge::RSS::RefreshLog.elapsed_ms(started),
      }.merge(extra)
    )
  end
end
