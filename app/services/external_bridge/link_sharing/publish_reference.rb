# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Asks for one distribution of a reference note.
    #
    # The worker locks the mapping, runs PublishStatusService, then sets
    # published_at. Reuse looks at published_at, so an expired Redis key
    # does not enqueue distribution again. This method claims the row
    # before perform_async. A second ensure while that claim is current
    # does not add another job. A nil jid leaves the row retryable.
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

        RecoverySchedule.enqueue!(@mapping.id)
      end
    end
  end
end
