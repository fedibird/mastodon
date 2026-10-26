# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Downloads one candidate for a resource revision. The URL is read back
      # from the current candidate list, not from the job arguments. A stale
      # revision or a removed candidate does not attach anything. Videos are
      # stored only when the server policy is hybrid at execution time and the
      # size is known and inside the cap.
      class Fetch
        include Redisable

        INFLIGHT_KEY = 'external_bridge:rss_media:inflight'
        TRANSIENT = %w(rate_limited fetch_failed).freeze

        def self.transient?(code)
          TRANSIENT.include?(code.to_s)
        end

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
            %w(image video).include?(candidate['kind']) && MediaDigest.url_digest(candidate['url']) == url_digest
          end
        end

        def download(resource, candidate, url_digest, media_revision)
          return download_video(resource, candidate, url_digest, media_revision) if candidate['kind'] == 'video'

          with_inflight { store_image(resource, candidate, url_digest, media_revision) }
        rescue Error => e
          raise if self.class.transient?(e.code)

          AssetStore.fail!(url_digest, candidate['kind'], media_revision, e.code)
          nil
        end

        def download_video(resource, candidate, url_digest, media_revision)
          return nil unless Policy.hybrid?

          outcome = with_inflight { VideoTransfer.new.call(candidate) }
          return store_video(resource, url_digest, media_revision, outcome.result) if outcome&.result
          return raise_transient(outcome) unless outcome.nil? || outcome.terminal

          AssetStore.fail!(url_digest, 'video', media_revision, outcome&.code || 'remote_only', terminal: true)
          nil
        end

        def raise_transient(outcome)
          raise Error, outcome.code.presence || 'fetch_failed'
        end

        def store_video(resource, url_digest, media_revision, result)
          return nil if resource.reload.media_revision.to_s != media_revision.to_s

          URLLock.call(url_digest) do
            return nil unless Policy.hybrid?

            AssetStore.store!(url_digest: url_digest, kind: 'video', revision: media_revision, result: result)
          end
        end

        def store_image(resource, candidate, url_digest, media_revision)
          URLLock.call(url_digest) do
            result = ImageFetch.new.call(candidate['url'])
            return nil if resource.reload.media_revision.to_s != media_revision.to_s

            AssetStore.store!(url_digest: url_digest, kind: 'image', revision: media_revision, result: result)
          end
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

        # A full slot is a delay, not a broken image. Wait, then let Sidekiq
        # retry if the server is still busy. The failure counter is not moved.
        def with_inflight
          deadline = clock + Limits::MEDIA_INFLIGHT_WAIT
          loop do
            if acquire_inflight
              begin
                return yield
              ensure
                release_inflight
              end
            end
            raise Error, :rate_limited if clock >= deadline

            sleep 0.02
          end
        end

        def acquire_inflight
          allowed = false
          with_redis do |redis|
            count = redis.incr(INFLIGHT_KEY)
            redis.expire(INFLIGHT_KEY, 120)
            if count.to_i > Limits::MEDIA_INFLIGHT
              redis.decr(INFLIGHT_KEY)
            else
              allowed = true
            end
          end
          allowed
        end

        def clock
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
