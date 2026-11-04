# frozen_string_literal: true

module FeedDelivery
  # Aggregate counters only. Field names are a closed list, so the Redis hash
  # cannot grow with accounts, statuses, keywords, or status text.
  #
  # record never writes one Redis command per destination. Pending totals are
  # flushed in one pipeline at FLUSH_SIZE, from a 5 second thread, from an
  # explicit flush! (keyword fan-out and process exit), or on the next retry
  # after a failed write. A failed write keeps the pending totals.
  module Metrics
    KEY_PREFIX = 'feed_delivery_reason:v1'
    RETENTION = 8.days
    PERSIST_FAILURE_FIELD = 'meta|result=persist_failure'
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

    def record(field, count = 1, now: Time.now.utc)
      return unless FIELDS.include?(field)
      return unless count.is_a?(Integer) && count.positive?

      should_flush = false
      synchronize do
        @counts[field] = @counts.fetch(field, 0) + count
        @pending[field] = @pending.fetch(field, 0) + count
        @pending_events += count
        should_flush = @pending_events >= FLUSH_SIZE
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
        @last_persist_warn = nil
      end
    end

    def flush!(now: Time.now.utc)
      pending, failures, events = synchronize do
        next if @pending_events.zero?

        extracted = @pending
        count = @pending_events
        @pending = Hash.new(0)
        @pending_events = 0
        [extracted, @persist_failures, count]
      end
      return false if pending.nil?

      payload = pending.dup
      payload[PERSIST_FAILURE_FIELD] = failures if failures.positive?
      write_redis(payload, now)
      synchronize do
        @redis_flushes += 1
        @persist_failures = 0
      end
      true
    rescue StandardError => e
      restore_pending(pending, events)
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

            flush!
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

    def restore_pending(pending, events)
      return if pending.nil?

      synchronize do
        pending.each { |field, count| @pending[field] = @pending.fetch(field, 0) + count }
        @pending_events += events.to_i
        @persist_failures += 1
      end
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
    @last_persist_warn = nil
    @flusher = nil
    @flusher_stop = false
    extend Redisable
    module_function :record, :snapshot, :pending_events, :persist_failures, :reset!, :flush!, :flush_count,
                    :start_flusher!, :stop_flusher!, :key_for, :synchronize, :write_redis, :restore_pending,
                    :warn_persist_failure

    at_exit { flush! } unless Rails.env.test?
  end
end
