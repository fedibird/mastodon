# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One tail batch, then a successor when the snapshot or a newer
    # generation is still open. No until_executed lock: this job enqueues
    # its successor before it returns, and that lock would drop the push.
    # The snapshot lease is what keeps two workers off the same cursor.
    class FeedSnapshotDrainWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5

      def perform(source_id)
        return unless ExternalBridge::Feature.enabled?

        result = FeedSnapshot::Drain.new.advance!(source_id)
        schedule_busy_retry(source_id) if result == :busy
      end

      private

      # Inline tests run perform_in immediately and would recurse while the
      # lease is still held. Production retries after the lease can lapse
      # so a killed worker is not stuck until the next feed poll.
      def schedule_busy_retry(source_id)
        return if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?

        self.class.perform_in(Limits::SNAPSHOT_LEASE.to_i, source_id)
      end
    end
  end
end
