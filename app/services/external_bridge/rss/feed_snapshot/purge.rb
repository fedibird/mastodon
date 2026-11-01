# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # Removes finished snapshot bodies. Open rows stay, so a drain in
      # progress cannot lose its text.
      #
      # A body is eligible SNAPSHOT_BODY_RETENTION after the snapshot
      # finishes. The RSS scheduler runs this even when no feed is due, so
      # an idle source does not keep the text until the next fetch. The pass
      # is batched. Deletion is the pass, not the exact retention instant.
      #
      # Finished bodies also yield when their total byte_size exceeds
      # SNAPSHOT_RETAINED_BODY_BYTES, oldest first, complete rows before
      # incomplete or failed ones. Before the body is nulled, FeedSnapshot::Retry
      # can reparse isolated positions. After body_purged_at is set, retry
      # reports snapshot_body_purged and does not invent items. The header
      # (cursor, isolated positions, error) remains.
      class Purge
        FINISHED = %w(complete incomplete failed).freeze

        def self.call
          new.call
        end

        def self.expired!(limit = Limits::SNAPSHOT_PURGE_BATCH)
          new.expire(limit)
        end

        def call
          expired = expire(Limits::SNAPSHOT_PURGE_BATCH)
          capped = release_over_cap(Limits::SNAPSHOT_PURGE_BATCH)
          retained = retained_bytes
          isolated = isolated_count
          if expired.positive? || capped.positive? || retained.positive? || isolated.positive?
            RefreshLog.emit('snapshot', outcome: 'snapshot_purged', purged: expired + capped, retained_bytes: retained, isolated: isolated)
          end
          expired + capped
        rescue StandardError => e
          RefreshLog.emit('snapshot', outcome: 'snapshot_failed', error_class: e.class)
          0
        end

        def expire(limit)
          null_bodies(due_ids(limit))
        end

        def release_over_cap(limit)
          removed = 0
          limit.times do
            break if retained_bytes <= Limits::SNAPSHOT_RETAINED_BODY_BYTES

            id = finished_with_body.order(Arel.sql('COALESCE(completed_at, updated_at) ASC'), :id).pick(:id)
            break if id.nil?

            removed += null_bodies([id])
          end
          removed
        end

        private

        def due_ids(limit)
          cutoff = Limits::SNAPSHOT_BODY_RETENTION.ago
          finished_with_body.where('COALESCE(completed_at, updated_at) < ?', cutoff).order(:id).limit(limit).pluck(:id)
        end

        def finished_with_body
          ExternalFeedSnapshot.where.not(body: nil).where(state: FINISHED)
        end

        def null_bodies(ids)
          return 0 if ids.empty?

          ExternalFeedSnapshot.where(id: ids).where.not(body: nil).update_all(body: nil, body_purged_at: Time.current, updated_at: Time.current)
        end

        def retained_bytes
          finished_with_body.sum(:byte_size).to_i
        end

        def isolated_count
          ExternalFeedSnapshot.where('jsonb_array_length(isolated_positions) > 0').count
        end
      end
    end
  end
end
