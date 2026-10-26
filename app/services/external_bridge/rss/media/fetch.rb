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

          existing = ExternalMediaAsset.find_by(url_digest: url_digest)
          return if existing&.exhausted_for?(media_revision) || existing&.processing_blocked?(media_revision)

          asset = existing if existing&.ready?
          asset ||= download(resource, candidate, url_digest, media_revision)
          return if asset.nil? || asset.processing_blocked?(media_revision)
          return unless asset.ready? || retryable_attachment?(asset)
          return if resource.reload.media_revision.to_s != media_revision.to_s

          AssetResource.remember!(asset.id, resource.id)
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

        # The digest lock is taken before HEAD and GET. A second resource that
        # waits finds the stored row and does not download the body again.
        # Policy is read again after the wait so a switch back to remote does
        # not finish a transfer that was already queued.
        def download_video(resource, candidate, url_digest, media_revision)
          return nil unless Policy.hybrid?

          with_inflight do
            URLLock.call(url_digest) do
              locked_video(resource, candidate, url_digest, media_revision)
            end
          end
        end

        def locked_video(resource, candidate, url_digest, media_revision)
          return nil if stale_revision?(resource, media_revision)
          return nil unless Policy.hybrid?

          cached = stored_copy(url_digest, media_revision)
          return cached if cached

          outcome = VideoTransfer.new.call(candidate)
          return store_video(resource, url_digest, media_revision, outcome.result) if outcome&.result

          AssetStore.fail!(
            url_digest,
            'video',
            media_revision,
            outcome&.code || 'remote_only',
            terminal: outcome.nil? || outcome.terminal
          )
          nil
        rescue ActiveRecord::RecordInvalid, Paperclip::Error
          AssetStore.processing_fail!(url_digest, 'video', media_revision, 'processing_failed')
          nil
        end

        def store_video(resource, url_digest, media_revision, result)
          return nil if stale_revision?(resource, media_revision)
          return nil unless Policy.hybrid?

          cached = stored_copy(url_digest, media_revision)
          return cached if cached

          AssetStore.store!(url_digest: url_digest, kind: 'video', revision: media_revision, result: result)
        end

        def store_image(resource, candidate, url_digest, media_revision)
          last_error = nil
          ImageAttempts.urls(candidate).each do |url|
            return nil if stale_revision?(resource, media_revision)

            asset = fetch_image(resource, url, media_revision)
            next if asset.nil?

            remember_alternate!(url, url_digest, media_revision)
            return asset
          rescue Error => e
            last_error = e
            raise if ImageAttempts.stop?(e.code) || !ImageAttempts.try_next?(e.code)
          end
          raise last_error if last_error

          nil
        end

        def fetch_image(resource, url, media_revision)
          digest = MediaDigest.url_digest(url)
          URLLock.call(digest) do
            cached = stored_copy(digest, media_revision)
            next cached if cached

            result = ImageFetch.new.call(url)
            raise Error, 'http_304' if result.not_modified || result.body.blank?
            next nil if stale_revision?(resource, media_revision)

            AssetStore.store!(url_digest: digest, kind: 'image', revision: media_revision, result: result)
          end
        end

        def remember_alternate!(url, primary_digest, media_revision)
          return if MediaDigest.url_digest(url) == primary_digest

          AssetStore.mark_alternate!(primary_digest, media_revision)
        end

        def stored_copy(url_digest, media_revision)
          existing = ExternalMediaAsset.find_by(url_digest: url_digest)
          return existing if existing&.ready?
          return nil unless existing&.processing_failed?
          return nil if existing.processing_blocked?(media_revision)
          return nil if existing.file_file_name.blank?

          existing
        end

        def retryable_attachment?(asset)
          asset.processing_failed? && asset.file_file_name.present?
        end

        def stale_revision?(resource, media_revision)
          resource.reload.media_revision.to_s != media_revision.to_s
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
