# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # Removes snapshot text that is no longer the only copy of an
      # unprocessed position.
      #
      # Disposable bodies become eligible SNAPSHOT_BODY_RETENTION after they
      # finish. A pending or running catch-up pins the snapshot it is inside
      # and every later generation it has not entered, so that text is not
      # disposable. stopped and done cursors do not pin: a paused subscriber
      # does not reserve the body, and resume skips a generation whose text
      # is already gone. A failed remainder or a retryable isolated position
      # keeps its body until Retry finishes it. That is an operator decision.
      #
      # If disposable bodies are not enough to fit SNAPSHOT_RETAINED_BODY_BYTES,
      # nothing recoverable is deleted. Capture then refuses the new response
      # and leaves etag where it is, so the bytes can be fetched again.
      class Purge
        def self.call
          new.call
        end

        def self.expired!(limit = Limits::SNAPSHOT_PURGE_BATCH)
          new.expire(limit)
        end

        def call
          expired = 0
          capped = 0
          ApplicationRecord.transaction do
            ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{Limits::SNAPSHOT_CAPACITY_LOCK})")
            expired = expire(Limits::SNAPSHOT_PURGE_BATCH)
            capped = release_over_cap(Limits::SNAPSHOT_PURGE_BATCH)
          end
          report(expired, capped)
          expired + capped
        rescue StandardError => e
          RefreshLog.emit('snapshot', outcome: 'snapshot_failed', error_class: e.class)
          0
        end

        def report(expired, capped)
          return unless expired.positive? || capped.positive?

          RefreshLog.emit(
            'snapshot',
            outcome: 'snapshot_purged',
            purged: expired + capped,
            retained_bytes: ExternalFeedSnapshot.held_body_bytes,
            isolated: isolated_count,
            unprocessed: ExternalFeedSnapshot.unprocessed_count
          )
        end

        def expire(limit)
          null_bodies(due_ids(limit))
        end

        def release_over_cap(limit)
          removed = 0
          limit.times do
            break if ExternalFeedSnapshot.held_body_bytes <= Limits::SNAPSHOT_RETAINED_BODY_BYTES

            id = ExternalFeedSnapshot.body_disposable.order(Arel.sql('COALESCE(completed_at, updated_at) ASC'), :id).pick(:id)
            break if id.nil?

            removed += null_bodies([id])
          end
          removed
        end

        private

        def due_ids(limit)
          cutoff = Limits::SNAPSHOT_BODY_RETENTION.ago
          ExternalFeedSnapshot.body_disposable.where('COALESCE(completed_at, updated_at) < ?', cutoff).order(:id).limit(limit).pluck(:id)
        end

        def null_bodies(ids)
          return 0 if ids.empty?

          ExternalFeedSnapshot.body_disposable.where(id: ids).update_all(body: nil, body_purged_at: Time.current, updated_at: Time.current)
        end

        def isolated_count
          ExternalFeedSnapshot.where('jsonb_array_length(isolated_positions) > 0').count
        end
      end
    end
  end
end
