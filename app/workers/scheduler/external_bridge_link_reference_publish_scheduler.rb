# frozen_string_literal: true

# Picks up reference mappings whose published_at is still null. One pass
# enqueues at most RecoverUnpublished::BATCH jobs. It does not read the
# feature flag: turning the flag off does not strand a note that was already
# created. Sidekiq retry on the publish worker covers a job that was accepted
# and then failed. This scheduler covers a job that was never accepted.
class Scheduler::ExternalBridgeLinkReferencePublishScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  def perform
    enqueued = ExternalBridge::LinkSharing::RecoverUnpublished.call
    Rails.logger.info("[Scheduler::ExternalBridgeLinkReferencePublishScheduler] candidates=#{enqueued}")
    enqueued
  end
end
