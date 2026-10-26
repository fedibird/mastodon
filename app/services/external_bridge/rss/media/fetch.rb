# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Downloads one image candidate for a resource revision. The URL is read
      # back from the current candidate list, not from the job arguments.
      # A stale revision, a removed candidate, or a subscription that is gone
      # does not attach anything. Video files are not downloaded.
      class Fetch
        include Redisable

        INFLIGHT_KEY = 'external_bridge:rss_media:inflight'

        def call(resource_id, media_revision, url_digest)
          resource = ExternalResource.find_by(id: resource_id)
          return if resource.nil? || resource.media_revision.to_s != media_revision.to_s
          return unless permitted_subscriber?(resource)

          candidate = candidate_for(resource, url_digest)
          return if candidate.nil?
          return if ExternalMediaAsset.find_by(url_digest: url_digest)&.exhausted_for?(media_revision)

          asset = AssetStore.ready(url_digest) || download(resource, candidate, url_digest, media_revision)
          return if asset.nil? || !asset.ready?
          return if resource.reload.media_revision.to_s != media_revision.to_s

          attach_all(resource)
        end

        private

        def permitted_subscriber?(resource)
          ExternalSubscription.where(external_source_id: resource.external_source_id, state: 'active').includes(:user).any? do |subscription|
            subscription.user&.functional? && Feature.permitted?(subscription.user)
          end
        end

        def candidate_for(resource, url_digest)
          Array(resource.media_candidates).find do |candidate|
            candidate['kind'] == 'image' && MediaDigest.url_digest(candidate['url']) == url_digest
          end
        end

        def download(resource, candidate, url_digest, media_revision)
          with_inflight { store(resource, candidate, url_digest, media_revision) }
        rescue Error => e
          AssetStore.fail!(url_digest, 'image', media_revision, e.code)
          nil
        end

        def store(resource, candidate, url_digest, media_revision)
          result = ImageFetch.new.call(candidate['url'])
          return nil if resource.reload.media_revision.to_s != media_revision.to_s

          AssetStore.store!(url_digest: url_digest, kind: 'image', revision: media_revision, result: result)
        end

        def attach_all(resource)
          resource.external_status_projections.includes(:external_subscription, :status).find_each do |marker|
            SubscriptionFence.guard!(marker.external_subscription_id) do
              changed = Sync.attach_ready!(marker, resource)
              Sync.notify!(marker) if changed
            end
          rescue SubscriptionFence::Fenced, ActiveRecord::ActiveRecordError, Paperclip::Error => e
            Rails.logger.info("[ExternalBridge::RSS] media attach skipped error=#{e.class}")
          end
        end

        def with_inflight
          acquired = false
          with_redis do |redis|
            count = redis.incr(INFLIGHT_KEY)
            redis.expire(INFLIGHT_KEY, 120)
            if count.to_i > Limits::MEDIA_INFLIGHT
              redis.decr(INFLIGHT_KEY)
              raise Error, :rate_limited
            end
            acquired = true
          end
          yield
        ensure
          release_inflight if acquired
        end

        def release_inflight
          with_redis do |redis|
            left = redis.decr(INFLIGHT_KEY)
            redis.del(INFLIGHT_KEY) if left.to_i <= 0
          end
        end
      end
    end
  end
end
