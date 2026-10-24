# frozen_string_literal: true

# Publishes the owner share-state event for flips that no event covered yet
# (see ExternalBridge::LinkSharing::RecoverUnnotified). Not gated by the
# feature flag: a state change that already happened belongs to the owner.
class Scheduler::ExternalBridgeLinkBoostNotifyScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 5.minutes.to_i

  def perform
    count = ExternalBridge::LinkSharing::RecoverUnnotified.call
    Rails.logger.info("[Scheduler::ExternalBridgeLinkBoostNotifyScheduler] candidates=#{count}")
    count
  end
end
