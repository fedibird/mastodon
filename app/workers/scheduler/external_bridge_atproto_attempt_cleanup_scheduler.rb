# frozen_string_literal: true

# Purges expired and consumed AT Protocol OAuth attempts. One run deletes
# at most AttemptCleanup::BATCH * AttemptCleanup::MAX_BATCHES rows.
class Scheduler::ExternalBridgeAtprotoAttemptCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    removed = ExternalBridge::Atproto::AttemptCleanup.call
    Rails.logger.info("[Scheduler::ExternalBridgeAtprotoAttemptCleanupScheduler] removed=#{removed}")
    removed
  end
end
