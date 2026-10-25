# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Fetches the shared icon of one external source (issue #569). The queue
    # push is unique per source, so a burst of feed refreshes, the backfill
    # scheduler, and a new subscription still produce one download.
    class IconRefreshWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 3, lock: :until_executed, lock_ttl: 15.minutes.to_i

      def perform(source_id)
        Icon::RefreshSource.new.call(source_id)
      end
    end
  end
end
