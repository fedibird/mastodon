# frozen_string_literal: true

module FeedDelivery
  # Aggregate counters only. Field names are a closed list, so the Redis hash
  # cannot grow with accounts, statuses, keywords, or status text.
  module Metrics
    KEY_PREFIX = 'feed_delivery_reason:v1'
    RETENTION = 8.days

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

    # count is the number of events to add. Redis is not touched on every call.
    # Pending totals flush in one pipeline after FLUSH_SIZE events, after
    # FLUSH_INTERVAL seconds, or when flush! is called.
    def record(field, count = 1, now: Time.now.utc)
      return unless FIELDS.include?(field)
      return unless count.is_a?(Integer) && count.positive?

      should_flush = false
      synchronize do
        @counts[field] = @counts.fetch(field, 0) + count
        @pending[field] = @pending.fetch(field, 0) + count
        @pending_events += count
        should_flush = @pending_events >= FLUSH_SIZE || flush_interval_elapsed?(now)
      end
      flush!(now: now) if should_flush
    end

    def snapshot
      synchronize do
        copy = {}
        @counts.each { |key, value| copy[key] = value }
        copy
      end
    end

    def reset!
      synchronize do
        @counts = Hash.new(0)
        @pending = Hash.new(0)
        @pending_events = 0
        @redis_flushes = 0
        @last_flush = Time.now.utc
      end
    end

    def flush!(now: Time.now.utc)
      pending = synchronize do
        next if @pending_events.zero?

        extracted = @pending
        @pending = Hash.new(0)
        @pending_events = 0
        @last_flush = now
        extracted
      end
      return false if pending.nil?

      persist(pending, now)
      true
    end

    def flush_count
      synchronize { @redis_flushes }
    end

    def key_for(time)
      "#{KEY_PREFIX}:#{time.utc.strftime('%Y%m%d%H')}"
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    def persist(fields, now)
      synchronize { @redis_flushes += 1 }
      key = key_for(now)
      with_redis do |connection|
        connection.pipelined do |pipeline|
          fields.each { |field, count| pipeline.hincrby(key, field, count) }
          pipeline.expire(key, RETENTION.to_i)
        end
      end
    rescue StandardError
      nil
    end

    def flush_interval_elapsed?(now)
      !@last_flush.nil? && (now - @last_flush) >= FLUSH_INTERVAL
    end

    @mutex = Mutex.new
    @counts = Hash.new(0)
    @pending = Hash.new(0)
    @pending_events = 0
    @redis_flushes = 0
    @last_flush = Time.now.utc
    extend Redisable
    module_function :record, :snapshot, :reset!, :flush!, :flush_count, :key_for, :synchronize, :persist, :flush_interval_elapsed?
  end
end
