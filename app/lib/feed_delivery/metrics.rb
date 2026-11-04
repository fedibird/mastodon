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

    def record(field, now: Time.now.utc)
      return unless FIELDS.include?(field)

      synchronize { @counts[field] = @counts.fetch(field, 0) + 1 }
      persist(field, now)
    end

    def snapshot
      synchronize do
        copy = {}
        @counts.each { |key, value| copy[key] = value }
        copy
      end
    end

    def reset!
      synchronize { @counts = Hash.new(0) }
    end

    def key_for(time)
      "#{KEY_PREFIX}:#{time.utc.strftime('%Y%m%d%H')}"
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    def persist(field, now)
      key = key_for(now)
      with_redis do |connection|
        connection.pipelined do |pipeline|
          pipeline.hincrby(key, field, 1)
          pipeline.expire(key, RETENTION.to_i)
        end
      end
    rescue StandardError
      nil
    end

    @mutex = Mutex.new
    @counts = Hash.new(0)
    extend Redisable
    module_function :record, :snapshot, :reset!, :key_for, :synchronize, :persist
  end
end
