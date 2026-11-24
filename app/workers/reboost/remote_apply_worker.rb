# frozen_string_literal: true

class Reboost::RemoteApplyWorker
  include Sidekiq::Worker
  include Redisable
  include Lockable

  sidekiq_options queue: 'pull', retry: 5

  def perform(hold_id)
    # perform_at runs inline in tests. A reschedule must not enter this method again
    # on the same thread, or a frozen clock (travel) retries the lock forever.
    return if Thread.current[:reboost_remote_apply]

    preview = RemoteReboostHold.find_by(id: hold_id)
    return if preview.nil?
    return if reschedule_if_early(preview)

    with_redis_lock(Reboost::AnnounceLock.key(preview.account_id, preview.reblog_of_id)) do
      hold = RemoteReboostHold.find_by(id: hold_id)
      return if hold.nil?
      return if reschedule_if_early(hold)

      uri = hold.activity_uri
      ActivityPub::Activity::Announce.new(hold.payload, hold.account, **apply_options(hold)).perform
      RemoteReboostHold.where(id: hold.id, activity_uri: uri).delete_all
    end
  end

  private

  def apply_options(hold)
    stored = hold.delivery_options || {}
    options = {
      applying_hold: true,
      delivery: stored.fetch('delivery', true),
      override_timestamps: stored.fetch('override_timestamps', true),
    }
    options[:delivered_to_account_id] = stored['delivered_to_account_id'] if stored['delivered_to_account_id']
    relay_id = stored['relayed_through_account_id']
    options[:relayed_through_account] = Account.find_by(id: relay_id) if relay_id
    options
  end

  def reschedule_if_early(hold)
    remaining = ReboostCooldown.remaining_seconds(hold.account_id, hold.reblog_of_id)
    return false unless remaining.positive?

    later = [hold.available_at, remaining.seconds.from_now].max
    Thread.current[:reboost_remote_apply] = true
    self.class.perform_at(later, hold.id)
    true
  ensure
    Thread.current[:reboost_remote_apply] = false
  end
end
