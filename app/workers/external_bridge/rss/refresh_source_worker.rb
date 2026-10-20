# frozen_string_literal: true

module ExternalBridge
  module RSS
    class RefreshSourceWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5, lock: :until_executed, lock_ttl: 15.minutes.to_i

      def perform(source_id, subscription_id = nil)
        return unless ExternalBridge::Feature.enabled?

        RefreshSource.new.call(source_id, subscription_id: subscription_id)
      end
    end
  end
end
