# frozen_string_literal: true

module ExternalBridge
  # Runs LinkSharing::BoostAnnounce for one boost row. Enqueued after the boost
  # commits, after the reference Create is distributed, and by the recovery
  # scan. Idempotent: the service locks the policy and the boost row, announced_at is the committed intent, and announce_enqueued_at is the mark that the ActivityPub job was accepted.
  class LinkBoostAnnounceWorker
    include Sidekiq::Worker

    sidekiq_options retry: 5

    def perform(boost_id)
      LinkSharing::BoostAnnounce.call(boost_id)
    end
  end
end
