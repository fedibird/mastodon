# frozen_string_literal: true

# Picks up reference mappings whose published_at is still null. One pass
# enqueues at most RecoverUnpublished::BATCH jobs, skipping rows already
# claimed by an accepted job. It does not read the feature flag: turning the
# flag off does not strand a note that was already created. Sidekiq retry on
# the publish worker covers a job that was accepted and then failed. This
# scheduler covers a job that was never accepted, and it moves past a head
# that stays unprocessed.
#
# The same pass also covers E4-B boost rows whose Announce was never handed to
# distribution (RecoverUnannounced) and closes boost rows whose projection is
# gone. Those rows are selected only after the reference Create is distributed.
# It also re-pushes RemovalWorker (the Undo) for a wrapper whose share has ended
# but whose removal was never handed over (RecoverRemovals).
class Scheduler::ExternalBridgeLinkReferencePublishScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 10.minutes.to_i

  def perform
    enqueued = ExternalBridge::LinkSharing::RecoverUnpublished.call
    announces = ExternalBridge::LinkSharing::RecoverUnannounced.call
    removals = ExternalBridge::LinkSharing::RecoverRemovals.call
    Rails.logger.info("[Scheduler::ExternalBridgeLinkReferencePublishScheduler] candidates=#{enqueued} announce_candidates=#{announces} removal_candidates=#{removals}")
    enqueued
  end
end
