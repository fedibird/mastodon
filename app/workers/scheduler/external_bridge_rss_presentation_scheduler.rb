# frozen_string_literal: true

# Recovers a per-subscription display rewrite whose push was refused or whose
# worker died before the generation was fully applied. One pass queues at most
# 50 subscriptions. Not gated by the ExternalBridge flags: the choice is a
# private display setting and stays in force when import is turned off.
class Scheduler::ExternalBridgeRSSPresentationScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  BATCH = 50
  # A failed generation is left alone briefly so a crash loop does not queue
  # a rewrite on every tick. The next save clears the error at once.
  ERROR_BACKOFF = 5.minutes

  def perform
    recovered = recover
    Rails.logger.info("[Scheduler::ExternalBridgeRSSPresentationScheduler] recovered=#{recovered}")
    recovered
  end

  private

  def recover
    now = Time.current
    due = ExternalSubscription.where.not(state: ExternalSubscription::DELETING)
                              .where('presentation_revision > presentation_applied_revision')
                              .where('presentation_lease_until IS NULL OR presentation_lease_until <= ?', now)
                              .where('presentation_error IS NULL OR updated_at <= ?', now - ERROR_BACKOFF)
                              .order(:id)
                              .limit(BATCH)
                              .pluck(:id, :presentation_revision)
    due.count do |subscription_id, revision|
      token = ExternalBridge::RSS::PresentationReconcileWorker.claim(subscription_id, revision)
      next false if token.nil?

      ExternalBridge::RSS::PresentationReconcileWorker.perform_async(subscription_id, revision.to_i, 0, token)
      true
    end
  end
end
