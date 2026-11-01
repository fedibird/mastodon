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

      # One delayed retry while the lease is still held. A second busy call
      # in that window does not enqueue again. The wait is the time left on
      # the lease, not another full lease stacked on the first. Inline tests
      # would run perform_in immediately and recurse.
      def schedule_busy_retry(source_id)
        return if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?

        snapshot = ExternalFeedSnapshot.open.where(external_source_id: source_id).order(:generation, :id).first
        return if snapshot.nil?

        wait = busy_wait(snapshot)
        claimed = ExternalFeedSnapshot.where(id: snapshot.id).where('busy_retry_at IS NULL OR busy_retry_at <= ?', Time.current).update_all(busy_retry_at: Time.current + wait)
        return if claimed.zero?

        self.class.perform_in(wait, source_id)
      end

      def busy_wait(snapshot)
        remaining = snapshot.lease_expires_at.present? ? snapshot.lease_expires_at - Time.current : Limits::SNAPSHOT_LEASE.to_i
        [[remaining.ceil, 1].max, Limits::SNAPSHOT_LEASE.to_i].min
      end
    end
  end
end
