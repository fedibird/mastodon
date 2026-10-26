# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # One download at a time for a normalized URL. The lock is checked again
      # before any HTTP call, so a worker that waited finds the ready asset
      # instead of fetching a second copy.
      class URLLock
        include Redisable

        def self.call(url_digest, &block)
          new.call(url_digest, &block)
        end

        def call(url_digest, &block)
          key = "external_bridge:rss_media:url:#{url_digest}"
          token = SecureRandom.hex(8)
          deadline = clock + Limits::MEDIA_URL_LOCK_WAIT
          until lock(key, token)
            ready = AssetStore.ready(url_digest)
            return ready if ready
            raise Error, :rate_limited if clock >= deadline

            sleep 0.02
          end
          begin
            ready = AssetStore.ready(url_digest)
            return ready if ready

            block.call
          ensure
            unlock(key, token)
          end
        end

        private

        def lock(key, token)
          locked = false
          with_redis { |redis| locked = redis.set(key, token, nx: true, ex: Limits::MEDIA_URL_LOCK_WAIT) }
          locked
        end

        def unlock(key, token)
          with_redis do |redis|
            redis.del(key) if redis.get(key) == token
          end
        end

        def clock
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
