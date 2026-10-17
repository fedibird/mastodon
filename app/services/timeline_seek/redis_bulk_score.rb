# frozen_string_literal: true

module TimelineSeek
  # One round trip for retained-window membership.
  #
  # Pipelined ZSCORE is one round trip and does not scan the ZSET. ZMSCORE
  # would also be one round trip on Redis 6.2+, but redis-namespace does not
  # prefix that command, and a process-wide or object_id cache of the choice
  # grows without bound and can be applied to a later client that reused the
  # id. Every connection, namespaced or not, uses the pipeline.
  class RedisBulkScore
    def initialize(redis)
      @redis = redis
    end

    def present_ids(key, ids)
      integers = ids.map { |id| Integer(id) }
      return [] if integers.empty?

      scores = pipelined_zscore(key, integers)
      integers.each_with_index.filter_map { |id, index| id unless scores[index].nil? }
    end

    private

    def pipelined_zscore(key, ids)
      @redis.pipelined do |pipeline|
        ids.each { |id| pipeline.zscore(key, id) }
      end
    end
  end
end
