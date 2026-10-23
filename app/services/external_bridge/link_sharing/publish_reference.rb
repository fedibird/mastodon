# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Distributes one reference note at most once.
    #
    # The mapping row is locked, then PublishStatusService runs, then
    # published_at is set. The Redis key inside PublishStatusService is only
    # the ordinary status mark and expires after 7 days. Reuse looks at
    # published_at, so an expired Redis key does not enqueue distribution
    # again. If this method raises before the update, published_at stays
    # null and the worker or the next ensure can retry. Two callers take
    # the same row lock, so only the first one reaches PublishStatusService.
    class PublishReference
      def self.call(mapping)
        new(mapping).call
      end

      def initialize(mapping)
        @mapping = mapping
      end

      def call
        return if @mapping.nil? || @mapping.id.nil?
        return if @mapping.published_at.present?

        jid = ExternalBridge::LinkReferencePublishWorker.perform_async(@mapping.id)
        if jid.blank?
          # Redis accepted nothing. published_at stays null and
          # next_recovery_at stays null, so the scheduler still selects it.
          Rails.logger.warn("[LinkSharing] reference publish was not enqueued mapping_id=#{@mapping.id}")
        else
          # Accepted. Hold the row out of the scheduler until the claim
          # expires so a waiting job is not pushed again every pass.
          RecoverySchedule.claim!(@mapping.id)
        end
        jid
      end
    end
  end
end
