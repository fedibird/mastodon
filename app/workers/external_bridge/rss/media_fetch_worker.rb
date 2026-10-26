# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One image URL for one resource revision. Arguments are ids and a digest,
    # never the article URL. Video files are not fetched by this worker.
    class MediaFetchWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 3, lock: :until_executed, lock_ttl: 15.minutes.to_i

      def perform(resource_id, media_revision, url_digest)
        Media::Fetch.new.call(resource_id, media_revision, url_digest)
      rescue ExternalBridge::Error => e
        raise if Media::Fetch.transient?(e.code)

        Rails.logger.info("[ExternalBridge::RSS] media fetch skipped code=#{e.code}")
      end
    end
  end
end
