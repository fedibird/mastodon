# frozen_string_literal: true

module TimelineSeek
  # One round trip for retained-window membership.
  # ZMSCORE is Redis 6.2+. Older servers use a pipelined ZSCORE, which is
  # still one round trip and does not scan the ZSET.
  class RedisBulkScore
    def initialize(redis)
      @redis = redis
    end

    def present_ids(key, ids)
      integers = ids.map { |id| Integer(id) }
      return [] if integers.empty?

      scores = scores_for(key, integers)
      integers.each_with_index.filter_map { |id, index| id unless scores[index].nil? }
    end

    def self.strategy_for(redis)
      return @strategy if defined?(@strategy) && @strategy

      @strategy = detect(redis)
    end

    def self.strategy_from_version(version)
      parts = version.to_s.split('.').first(3).map(&:to_i)
      return :pipeline if parts.empty? || parts.all?(&:zero?)

      (parts <=> [6, 2]).negative? ? :pipeline : :zmscore
    end

    def self.prefer_pipeline!
      @strategy = :pipeline
    end

    def self.reset_strategy!
      @strategy = nil
    end

    # redis-namespace still wraps this process when REDIS_NAMESPACE is set.
    # It does not implement ZMSCORE; a blind passthrough would miss the
    # namespace prefix. Pipelined ZSCORE stays one round trip and is prefixed.
    def self.detect(redis)
      return :pipeline if defined?(Redis::Namespace) && redis.is_a?(Redis::Namespace)

      info = redis.info('server')
      version = info.is_a?(Hash) ? (info['redis_version'] || info[:redis_version]) : nil
      strategy_from_version(version)
    rescue Redis::BaseError
      :pipeline
    end

    private

    def scores_for(key, ids)
      if self.class.strategy_for(@redis) == :zmscore
        zmscore(key, ids)
      else
        pipelined_zscore(key, ids)
      end
    end

    def zmscore(key, ids)
      Array(@redis.zmscore(key, ids.map(&:to_s)))
    rescue Redis::BaseError, NoMethodError
      self.class.prefer_pipeline!
      pipelined_zscore(key, ids)
    end

    def pipelined_zscore(key, ids)
      @redis.pipelined do |pipeline|
        ids.each { |id| pipeline.zscore(key, id) }
      end
    end
  end
end
