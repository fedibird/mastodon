# frozen_string_literal: true

module ExternalBridge
  module RSS
    class RefreshSourceWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5, lock: :until_executed, lock_ttl: 15.minutes.to_i

      def perform(source_id, subscription_id = nil)
        unless ExternalBridge::Feature.enabled?
          RefreshLog.emit(
            'refresh',
            source_id: source_id, subscription_id: subscription_id.presence || '-',
            outcome: 'skipped_feature_disabled', elapsed_ms: 0
          )
          return
        end

        RefreshSource.new.call(source_id, subscription_id: subscription_id)
      end
    end
  end
end
