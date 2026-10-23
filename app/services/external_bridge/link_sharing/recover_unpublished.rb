# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # The mapping row is the outbox. published_at NULL means distribution has
    # not finished. EnsureReference enqueues immediately after commit; this
    # scan covers the window where that enqueue never happened, returned nil,
    # or the process stopped before Sidekiq accepted the job.
    #
    # One pass takes at most BATCH rows, oldest unvisited first, then the
    # oldest elapsed next_recovery_at. A row whose job was accepted is claimed
    # until RecoverySchedule::CLAIM_FOR from now and is not pushed again on
    # the next passes. A nil jid, or a Redis error, records a visit at now
    # and creates no job. Never-visited rows are still selected ahead of that
    # visit, so a failing head does not starve the tail. After the claim
    # expires, a failed head can be tried again. One retry after the window
    # is not a new job every scheduler pass.
    #
    # Creation is gated by the feature flag and the current policy. Recovery
    # is not. A note that was already inserted stays eligible after the flag
    # is turned off or consent is revoked. Broken rows, discarded notes, and
    # projection statuses are not enqueued. The worker's row lock still
    # publishes at most once.
    class RecoverUnpublished
      BATCH = 20

      def self.call
        new.call
      end

      def call
        selected = ids
        selected.each { |id| enqueue(id) }
        selected.size
      end

      private

      def ids
        ExternalProjectionLinkReference
          .where(published_at: nil, state: %w(active superseded))
          .where.not(reference_status_id: nil)
          .where('external_projection_link_references.next_recovery_at IS NULL OR external_projection_link_references.next_recovery_at <= NOW()')
          .joins(recoverable_status_join)
          .where('statuses.deleted_at IS NULL')
          .where('statuses.external_projection IS NOT TRUE')
          .where('statuses.account_id = external_projection_link_references.account_id')
          .order(Arel.sql('external_projection_link_references.next_recovery_at ASC NULLS FIRST, external_projection_link_references.id ASC'))
          .limit(BATCH)
          .pluck(:id)
      end

      def recoverable_status_join
        'INNER JOIN statuses ON statuses.id = external_projection_link_references.reference_status_id'
      end

      def enqueue(id)
        return unless RecoverySchedule.claim!(id)

        jid = ExternalBridge::LinkReferencePublishWorker.perform_async(id)
        if jid.present?
          jid
        else
          RecoverySchedule.visit_without_claim!(id)
          Rails.logger.warn("[LinkSharing] unpublished reference was not enqueued mapping_id=#{id}")
          nil
        end
      rescue Redis::BaseError => e
        RecoverySchedule.visit_without_claim!(id)
        Rails.logger.warn("[LinkSharing] unpublished reference enqueue failed mapping_id=#{id} error=#{e.class}")
        nil
      end
    end
  end
end
