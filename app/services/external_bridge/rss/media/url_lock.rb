# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # One download at a time for a normalized URL. The Redis lease is renewed
      # until the download returns, so a GET longer than the first TTL does not
      # let a second worker start. The lock is checked again before HTTP.
      # Release deletes the key only when the owner token still matches.
      class URLLock
        include Redisable

        UNLOCK_LUA = <<~LUA
          if redis.call('get', KEYS[1]) == ARGV[1] then
            return redis.call('del', KEYS[1])
          else
            return 0
          end
        LUA
        RENEW_LUA = <<~LUA
          if redis.call('get', KEYS[1]) == ARGV[1] then
            return redis.call('expire', KEYS[1], ARGV[2])
          else
            return 0
          end
        LUA

        def self.call(url_digest, &block)
          new.acquire(url_digest, ready_check: true, &block)
        end

        # Same lease as a download, but the block still runs when a file is
        # already stored. Attachment conversion uses this. `call` returns the
        # ready row instead of fetching again.
        def self.exclusive(url_digest, &block)
          new.acquire(url_digest, ready_check: false, &block)
        end

        def acquire(url_digest, ready_check:, &block)
          key = "external_bridge:rss_media:url:#{url_digest}"
          token = SecureRandom.hex(8)
          deadline = clock + Limits::MEDIA_URL_LOCK_WAIT
          until lock(key, token)
            ready = ready_asset(url_digest, ready_check)
            return ready if ready
            raise Error, :rate_limited if clock >= deadline

            sleep 0.02
          end
          guard(key, token, url_digest, ready_check, &block)
        end

        private

        def guard(key, token, url_digest, ready_check, &block)
          ready = ready_asset(url_digest, ready_check)
          return ready if ready

          stop = Queue.new
          renewer = Thread.new { renew_until(stop, key, token) }
          begin
            block.call
          ensure
            stop.push(:stop)
            renewer.join(lease_seconds)
          end
        ensure
          unlock(key, token)
        end

        def ready_asset(url_digest, ready_check)
          return unless ready_check

          AssetStore.ready(url_digest)
        end

        def lock(key, token)
          locked = false
          with_redis { |redis| locked = redis.set(key, token, nx: true, ex: lease_seconds) }
          locked
        end

        def renew_until(stop, key, token)
          loop do
            signal = stop.pop(timeout: renew_interval)
            break if signal
            break unless renew(key, token)
          end
        rescue StandardError
          nil
        end

        def renew(key, token)
          renewed = false
          with_redis do |redis|
            renewed = redis.eval(RENEW_LUA, keys: [key], argv: [token, lease_seconds.to_s]).to_i == 1
          end
          renewed
        end

        def unlock(key, token)
          with_redis do |redis|
            redis.eval(UNLOCK_LUA, keys: [key], argv: [token])
          end
        end

        def lease_seconds
          [Limits::MEDIA_URL_LOCK_LEASE.to_i, 1].max
        end

        def renew_interval
          [lease_seconds / 3.0, 0.2].max
        end

        def clock
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
