# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # The mapping row is the outbox. published_at NULL means distribution has
    # not finished. EnsureReference enqueues immediately after commit; this
    # scan covers the window where that enqueue never happened, returned nil,
    # or the process stopped before Sidekiq accepted the job.
    #
    # Creation is gated by the feature flag and the current policy. Recovery
    # is not. A note that was already inserted stays eligible after the flag
    # is turned off or consent is revoked. Broken rows, discarded notes, and
    # projection statuses are not enqueued. A nil jid leaves the row eligible
    # for the next pass. The worker's row lock still publishes at most once.
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
          .joins(recoverable_status_join)
          .where('statuses.deleted_at IS NULL')
          .where('statuses.external_projection IS NOT TRUE')
          .where('statuses.account_id = external_projection_link_references.account_id')
          .order(:id)
          .limit(BATCH)
          .pluck(:id)
      end

      def recoverable_status_join
        'INNER JOIN statuses ON statuses.id = external_projection_link_references.reference_status_id'
      end

      def enqueue(id)
        jid = ExternalBridge::LinkReferencePublishWorker.perform_async(id)
        return jid if jid.present?

        Rails.logger.warn("[LinkSharing] unpublished reference was not enqueued mapping_id=#{id}")
        nil
      end
    end
  end
end
