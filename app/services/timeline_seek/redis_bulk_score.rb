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

    # Capability is a property of this connection object. A namespaced client
    # must not publish :pipeline into a cache that a later raw client reads,
    # or the raw client would be fine while the namespace would send
    # unprefixed keys to ZMSCORE if the decision were reversed.
    def self.strategy_for(redis)
      return :pipeline if namespaced?(redis)

      strategies[connection_key(redis)] ||= detect_raw(redis)
    end

    def self.strategy_from_version(version)
      parts = version.to_s.split('.').first(3).map(&:to_i)
      return :pipeline if parts.empty? || parts.all?(&:zero?)

      (parts <=> [6, 2]).negative? ? :pipeline : :zmscore
    end

    def self.prefer_pipeline!(redis)
      return if redis.nil? || namespaced?(redis)

      strategies[connection_key(redis)] = :pipeline
    end

    def self.reset_strategy!
      @strategies = {}
    end

    def self.namespaced?(redis)
      defined?(Redis::Namespace) && redis.is_a?(Redis::Namespace)
    end

    def self.connection_key(redis)
      redis.object_id
    end

    def self.strategies
      @strategies ||= {}
    end

    # redis-namespace still wraps this process when REDIS_NAMESPACE is set.
    # It does not implement ZMSCORE; a blind passthrough would miss the
    # namespace prefix. Pipelined ZSCORE stays one round trip and is prefixed.
    def self.detect_raw(redis)
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
      self.class.prefer_pipeline!(@redis)
      pipelined_zscore(key, ids)
    end

    def pipelined_zscore(key, ids)
      @redis.pipelined do |pipeline|
        ids.each { |id| pipeline.zscore(key, id) }
      end
    end
  end
end
