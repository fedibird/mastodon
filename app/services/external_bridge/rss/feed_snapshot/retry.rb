# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # One explicit resume of a snapshot that stopped or isolated positions.
      # Nothing calls this on a timer. A poison position is retried only here,
      # and a failed remainder blocks newer generations until this runs.
      #
      # The body is required. After purge, the call records snapshot_body_purged
      # and leaves the header in place. It does not synthesize items.
      class Retry
        def self.call(snapshot_id)
          new(snapshot_id).call
        end

        def initialize(snapshot_id)
          @snapshot_id = snapshot_id
        end

        def call
          snapshot = ExternalFeedSnapshot.find_by(id: @snapshot_id)
          return :missing if snapshot.nil?
          return :busy if lease_held?(snapshot)
          return body_missing(snapshot) if snapshot.body.nil?
          return :nothing unless retryable?(snapshot)

          queued = reopen!(snapshot)
          return :not_retryable unless queued

          FeedSnapshotDrainWorker.perform_async(snapshot.external_source_id)
          :queued
        end

        private

        def lease_held?(snapshot)
          snapshot.lease_token.present? && snapshot.lease_expires_at.present? && snapshot.lease_expires_at > Time.current
        end

        def retryable?(snapshot)
          snapshot.blocked_remainder? || snapshot.isolated_entries.any? || snapshot.state == 'incomplete'
        end

        def body_missing(snapshot)
          snapshot.update!(last_error_code: 'snapshot_body_purged') if snapshot.persisted?
          RefreshLog.emit('snapshot', source_id: snapshot.external_source_id, snapshot_id: snapshot.id, outcome: 'snapshot_body_purged')
          :body_purged
        end

        def reopen!(snapshot)
          positions = snapshot.isolated_entries.map { |entry| entry['position'] }
          now = Time.current
          ExternalFeedSnapshot.where(id: snapshot.id, state: %w(failed incomplete))
                              .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
                              .update_all(
                                [
                                  "state = 'pending', attempt_count = 0, batch_count = 0, retry_positions = ?::jsonb, isolated_positions = '[]'::jsonb, lease_token = NULL, lease_expires_at = NULL, last_error_code = NULL, updated_at = ?",
                                  positions.to_json,
                                  now,
                                ]
                              ) == 1
        end
      end
    end
  end
end
