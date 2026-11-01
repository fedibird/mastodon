# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One catch-up batch for one subscription. The successor is enqueued by
    # FeedSnapshot::CatchUp when the cursor still has positions or a later
    # snapshot body. No until_executed lock, for the same reason as the drain
    # worker: the job enqueues itself before it returns.
    class FeedSnapshotCatchUpWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5

      def perform(subscription_id)
        return unless ExternalBridge::Feature.enabled?

        FeedSnapshot::CatchUp.advance!(subscription_id)
      end
    end
  end
end
