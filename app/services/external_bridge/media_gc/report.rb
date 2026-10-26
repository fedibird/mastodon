# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Counts and sample decisions. diagnose does not destroy files or rows.
    class Report
      def self.diagnose(sample:)
        counts = ExternalMediaGcIntent.group(:state).count
        {
          pending: counts['pending'].to_i,
          due: ExternalMediaGcIntent.due.count,
          released: counts['released'].to_i,
          retained: counts['retained'].to_i,
          failed: counts['failed'].to_i,
          by_reason: ExternalMediaGcIntent.pending.group(:reason).count,
          by_error: ExternalMediaGcIntent.where.not(last_error_code: nil).group(:last_error_code).count,
          grace_seconds: MediaGc.grace.to_i,
          batch: MediaGc::BATCH,
          max_attempts: MediaGc::MAX_ATTEMPTS,
          retention_seconds: MediaGc::RETENTION.to_i,
          samples: samples(sample),
        }
      end

      def self.prune_resolved!(limit:)
        cutoff = MediaGc::RETENTION.ago
        ids = ExternalMediaGcIntent.where(state: %w(released retained)).where('resolved_at < ?', cutoff).order(:id).limit(limit).pluck(:id)
        return 0 if ids.empty?

        ExternalMediaGcIntent.where(id: ids).delete_all
      end

      def self.requeue_failed!(limit:)
        ids = ExternalMediaGcIntent.where(state: 'failed').order(:id).limit(limit).pluck(:id)
        return 0 if ids.empty?

        now = Time.current
        ExternalMediaGcIntent.where(id: ids, state: 'failed').update_all(
          state: 'pending',
          attempt_count: 0,
          lease_token: nil,
          leased_until: nil,
          last_error_code: nil,
          available_at: now,
          resolved_at: nil,
          updated_at: now
        )
      end

      def self.samples(sample)
        return [] if sample.to_i <= 0

        ExternalMediaGcIntent.pending.order(:id).limit(sample.to_i).map { |intent| sample_row(intent) }
      end

      def self.sample_row(intent)
        decision = Classify.call(intent)
        {
          id: intent.id,
          target_type: intent.target_type,
          target_id: intent.target_id,
          reason: intent.reason,
          attempt_count: intent.attempt_count,
          last_error_code: intent.last_error_code,
          decision: decision.action.to_s,
          decision_code: decision.code,
        }
      end
    end
  end
end
