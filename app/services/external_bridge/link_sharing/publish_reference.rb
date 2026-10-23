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

        ExternalBridge::LinkReferencePublishWorker.perform_async(@mapping.id)
      end
    end
  end
end
