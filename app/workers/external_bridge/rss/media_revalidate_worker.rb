# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One conditional GET. Arguments are a resource id and a URL digest, never
    # the article URL.
    class MediaRevalidateWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 3, lock: :until_executed, lock_ttl: 15.minutes.to_i

      def perform(resource_id, url_digest)
        Media::Revalidate.call(resource_id, url_digest)
      rescue ExternalBridge::Error => e
        raise if Media::Fetch.transient?(e.code)

        Rails.logger.info("[ExternalBridge::RSS] media revalidate skipped code=#{e.code}")
      end
    end
  end
end
