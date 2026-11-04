# frozen_string_literal: true

module FeedDelivery
  # Aggregate counters only. Field names are a closed list, so the Redis hash
  # cannot grow with accounts, statuses, keywords, or status text.
  #
  # record never writes one Redis command per destination. Pending totals are
  # flushed in one pipeline at FLUSH_SIZE, from a 5 second thread, or from an
  # explicit flush! (keyword fan-out and process exit).
  #
  # After a failed write the batch stays pending. record will not try Redis
  # again until the backoff ends. The 5 second thread still calls
  # flush!(force: true), so each process retries about once per interval while
  # Redis is down. That is the recovery check: total attempts are roughly
  # process count divided by FLUSH_INTERVAL, not the delivery rate. Those
  # forced attempts are counted and, on the next successful write, stored as
  # meta|result=recovery_attempt. A successful write also clears the backoff.
  module Metrics
    KEY_PREFIX = 'feed_delivery_reason:v1'
    RETENTION = 8.days
    PERSIST_FAILURE_FIELD = 'meta|result=persist_failure'
    RECOVERY_ATTEMPT_FIELD = 'meta|result=recovery_attempt'
    WARN_INTERVAL = 60

    FIELDS = %w(
      kw|qual=reply|result=evidence
      kw|qual=reply|result=fallback
      kw|qual=reply|result=agree
      kw|qual=reply|result=disagree
      kw|qual=ignore_block|result=evidence
      kw|qual=ignore_block|result=fallback
      kw|qual=ignore_block|result=agree
      kw|qual=ignore_block|result=disagree
      list|result=reuse
      list|result=agree
      list|result=disagree
      job|reason=keyword
      crutches|event=build
    ).freeze

    FLUSH_SIZE = 100
    FLUSH_INTERVAL = 5
    MAX_BACKOFF = 60

    def record(field, count = 1, now: Time.now.utc)
      return unless FIELDS.include?(field)
      return unless count.is_a?(Integer) && count.positive?

      should_flush = false
      synchronize do
        @counts[field] = @counts.fetch(field, 0) + count
        @pending[field] = @pending.fetch(field, 0) + count
        @pending_events += count
        should_flush = @pending_events >= FLUSH_SIZE && !cooling_down?(now)
      end
      flush!(now: now) if should_flush
      start_flusher! unless Rails.env.test?
    end

    def snapshot
      synchronize do
        copy = {}
        @counts.each { |key, value| copy[key] = value }
        copy
      end
    end

    def pending_events
      synchronize { @pending_events }
    end

    def persist_failures
      synchronize { @persist_failures }
    end

    def reset!
      synchronize do
        @counts = Hash.new(0)
        @pending = Hash.new(0)
        @pending_events = 0
        @redis_flushes = 0
        @persist_failures = 0
        @recovery_attempts = 0
        @last_persist_warn = nil
        @retry_after = nil
      end
    end

    # force is the periodic flusher and process exit. record never forces, so a
    # Redis outage cannot turn every later event into a synchronous retry.
    # The flusher still retries about once per FLUSH_INTERVAL per process.
    def flush!(now: Time.now.utc, force: false)
      pending, failures, events, recovery = synchronize do
        next if @pending_events.zero?
        next if !force && cooling_down?(now)

        @recovery_attempts += 1 if force && cooling_down?(now)
        extracted = @pending
        count = @pending_events
        carried_failures = @persist_failures
        carried_recovery = @recovery_attempts
        @pending = Hash.new(0)
        @pending_events = 0
        @persist_failures = 0
        @recovery_attempts = 0
        [extracted, carried_failures, count, carried_recovery]
      end
      return false if pending.nil?

      payload = pending.dup
      payload[PERSIST_FAILURE_FIELD] = failures if failures.positive?
      payload[RECOVERY_ATTEMPT_FIELD] = recovery if recovery.positive?
      write_redis(payload, now)
      synchronize do
        @redis_flushes += 1
        @retry_after = nil
      end
      true
    rescue StandardError => e
      restore_pending(pending, events, failures, recovery)
      warn_persist_failure(e)
      false
    end

    def flush_count
      synchronize { @redis_flushes }
    end

    def start_flusher!(interval: FLUSH_INTERVAL)
      synchronize do
        return @flusher if @flusher&.alive?

        @flusher_stop = false
        @flusher = Thread.new(interval) do |pause|
          until @flusher_stop
            sleep pause
            break if @flusher_stop

            flush!(force: true)
          end
        end
        @flusher
      end
    end

    def stop_flusher!
      thread = synchronize do
        @flusher_stop = true
        current = @flusher
        @flusher = nil
        current
      end
      return unless thread&.alive?

      thread.wakeup
      thread.join(1)
    rescue ThreadError
      nil
    end

    def key_for(time)
      "#{KEY_PREFIX}:#{time.utc.strftime('%Y%m%d%H')}"
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    def write_redis(fields, now)
      key = key_for(now)
      with_redis do |connection|
        connection.pipelined do |pipeline|
          fields.each { |field, count| pipeline.hincrby(key, field, count) }
          pipeline.expire(key, RETENTION.to_i)
        end
      end
    end

    def restore_pending(pending, events, failures, recovery)
      return if pending.nil?

      synchronize do
        pending.each { |field, count| @pending[field] = @pending.fetch(field, 0) + count }
        @pending_events += events.to_i
        @persist_failures += failures.to_i + 1
        @recovery_attempts += recovery.to_i
        @retry_after = Time.now.utc + backoff_delay(@persist_failures)
      end
    end

    def cooling_down?(now)
      @retry_after && now < @retry_after
    end

    def backoff_delay(failures)
      exponent = [[failures.to_i - 1, 0].max, 4].min
      [FLUSH_INTERVAL * (2**exponent), MAX_BACKOFF].min
    end

    def warn_persist_failure(error)
      now = Time.now.utc
      should_warn = synchronize do
        next false if @last_persist_warn && (now - @last_persist_warn) < WARN_INTERVAL

        @last_persist_warn = now
        true
      end
      return unless should_warn

      Rails.logger.warn("[FeedDelivery] metrics persist failed error=#{error.class} failures=#{persist_failures}")
    rescue StandardError
      nil
    end

    @mutex = Mutex.new
    @counts = Hash.new(0)
    @pending = Hash.new(0)
    @pending_events = 0
    @redis_flushes = 0
    @persist_failures = 0
    @recovery_attempts = 0
    @last_persist_warn = nil
    @retry_after = nil
    @flusher = nil
    @flusher_stop = false
    extend Redisable
    module_function :record, :snapshot, :pending_events, :persist_failures, :reset!, :flush!, :flush_count,
                    :start_flusher!, :stop_flusher!, :key_for, :synchronize, :write_redis, :restore_pending,
                    :cooling_down?, :backoff_delay, :warn_persist_failure

    at_exit { flush!(force: true) } unless Rails.env.test?
  end
end
