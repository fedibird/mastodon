# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One catch-up batch for one subscription. The successor is enqueued by
    # FeedSnapshot::CatchUp when the cursor still has positions the shared
    # drain has already committed. A wait schedules one delayed retry.
    # No until_executed lock, for the same reason as the drain worker: the
    # job enqueues itself before it returns.
    class FeedSnapshotCatchUpWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5

      def perform(subscription_id)
        return unless ExternalBridge::Feature.enabled?

        result = FeedSnapshot::CatchUp.advance!(subscription_id)
        schedule_wait(subscription_id) if %i(waiting busy).include?(result)
      end

      private

      # One delayed retry while the shared cursor is still behind, or while
      # another worker holds this lease. A second call in that window does
      # not enqueue again. Inline tests would run perform_in immediately.
      def schedule_wait(subscription_id)
        return if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?

        row = ExternalFeedCatchUp.find_by(external_subscription_id: subscription_id)
        return if row.nil? || %w(done stopped).include?(row.state)

        wait = wait_seconds(row)
        claimed = ExternalFeedCatchUp.where(id: row.id).where('busy_retry_at IS NULL OR busy_retry_at <= ?', Time.current).update_all(busy_retry_at: Time.current + wait)
        return if claimed.zero?

        self.class.perform_in(wait, subscription_id)
      end

      def wait_seconds(row)
        remaining = row.lease_expires_at.present? ? row.lease_expires_at - Time.current : ExternalBridge::RSS::Limits::SNAPSHOT_LEASE.to_i
        [[remaining.ceil, 1].max, ExternalBridge::RSS::Limits::SNAPSHOT_LEASE.to_i].min
      end
    end
  end
end
