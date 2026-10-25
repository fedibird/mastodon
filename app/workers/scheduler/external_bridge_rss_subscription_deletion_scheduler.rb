# frozen_string_literal: true

# Recovery for asynchronous RSS unsubscribes. A record is pushed again when it
# is queued, running, or failed with attempts left and its next_run_at (the
# durable outbox / worker lease) has passed: the first push was refused, the web
# process died before it, or the worker was killed mid-run. Pushing is
# idempotent. Not gated by the ExternalBridge flags. Also drops old completed
# progress records.
class Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  BATCH = 50
  CLEANUP_BATCH = 500
  REPUSH_HOLD = 2.minutes

  def perform
    recovered = recover
    notices = ExternalBridge::RSS::SubscriptionRemovedNotice.recover!
    purged = cleanup
    Rails.logger.info(
      "[Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler] recovered=#{recovered} notices=#{notices} purged=#{purged}"
    )
    recovered
  end

  private

  # A due `failed` record becomes `queued` here, so the job that follows has the
  # right to run it (the runner never starts a `failed` record) and the card no
  # longer says "waiting to retry". A due `queued` or `running` record (a lost
  # push, a dead worker) is only held back for REPUSH_HOLD.
  def recover
    now = Time.current
    due = ExternalSubscriptionDeletion.pending.where('next_run_at <= ?', now).order(:next_run_at).limit(BATCH).pluck(:id, :next_run_at, :state)
    due.count do |id, due_at, state|
      attributes = { next_run_at: now + REPUSH_HOLD, updated_at: now }
      attributes[:state] = 'queued' if state == 'failed'
      held = ExternalSubscriptionDeletion.pending.where(id: id, next_run_at: due_at, state: state).update_all(attributes)
      next false if held.zero?

      ExternalBridge::RSS::SubscriptionDeletionLog.emit('recovered', job_id: id)
      ExternalBridge::RSS::SubscriptionDeletionDispatch.enqueue(id)
    end
  end

  def cleanup
    ids = ExternalSubscriptionDeletion.where(state: 'completed')
                                      .where('finished_at < ?', ExternalSubscriptionDeletion::RETENTION.ago)
                                      .limit(CLEANUP_BATCH).pluck(:id)
    ExternalSubscriptionDeletion.where(id: ids).delete_all
  end
end
