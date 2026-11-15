# frozen_string_literal: true

# Applies one held remote Announce after the account+original cooldown.
# The hold keeps the newest unseen id only. This does not reject the remote
# server, and it does not move the cooldown earlier.
class Reboost::RemoteApplyWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8

  def perform(hold_id)
    hold = RemoteReboostHold.find_by(id: hold_id)
    return if hold.nil?

    remaining = ReboostCooldown.remaining_seconds(hold.account_id, hold.reblog_of_id)
    if remaining.positive? && hold.available_at > 2.seconds.from_now
      return
    end

    payload = hold.payload
    account = hold.account
    uri = hold.activity_uri
    ActivityPub::Activity::Announce.new(payload, account, applying_hold: true).perform
    held = RemoteReboostHold.find_by(id: hold.id)
    return if held.nil?

    if Status.exists?(account_id: account.id, uri: held.activity_uri) || ReboostAnnounceState.superseded?(account.id, held.activity_uri)
      held.destroy!
    elsif hold.available_at <= Time.current
      later = Time.current + [ReboostCooldown.remaining_seconds(held.account_id, held.reblog_of_id), 5].max.seconds
      held.update!(available_at: later)
      self.class.perform_at(later, held.id)
    end
  end
end
