# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Releases one bounded batch of external_media_gc_intents. The argument
    # list is empty on purpose: a subscription can have far more statuses
    # than a job payload should carry, and the plan is already in the table.
    class MediaGcWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 0

      def perform
        result = ExternalBridge::MediaGc.drain!
        self.class.perform_in(1.second) if result[:more]
      end
    end
  end
end
