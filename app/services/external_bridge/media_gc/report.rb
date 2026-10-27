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
          rechecks_due: ExternalMediaGcAssetRecheck.due.count,
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
        pruned = ids.empty? ? 0 : ExternalMediaGcIntent.where(id: ids).delete_all
        prune_rechecks!(cutoff, limit)
        prune_proofs!(limit)
        pruned
      end

      # Done rechecks are only a record that a reference drop was settled.
      def self.prune_rechecks!(cutoff, limit)
        ids = ExternalMediaGcAssetRecheck.where(state: 'done').where('resolved_at < ?', cutoff).order(:id).limit(limit).pluck(:id)
        ExternalMediaGcAssetRecheck.where(id: ids).delete_all if ids.any?
      end

      # A proof stays while its attachment or a pending/failed intent needs
      # it. After both are gone, a new insert cannot retarget the link id:
      # the proof trigger requires the projection attachment to still exist.
      def self.prune_proofs!(limit)
        ExternalMediaGcProof.connection.execute(<<~SQL.squish)
          DELETE FROM external_media_gc_proofs
          WHERE id IN (
            SELECT proofs.id
            FROM external_media_gc_proofs AS proofs
            WHERE NOT EXISTS (
              SELECT 1 FROM media_attachments
              WHERE media_attachments.id = proofs.media_attachment_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM external_media_gc_intents AS intents
              WHERE intents.source_attachment_id = proofs.source_attachment_id
                AND intents.state IN ('pending', 'failed')
            )
            ORDER BY proofs.id
            LIMIT #{limit.to_i}
          )
        SQL
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
