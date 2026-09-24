# frozen_string_literal: true

class Trends::Base
  include Redisable
  include LanguagesHelper

  class_attribute :default_options

  attr_reader :options

  def initialize(options = {})
    @options = self.class.default_options.merge(options)
  end

  def register(_status)
    raise NotImplementedError
  end

  def add(*)
    raise NotImplementedError
  end

  def refresh(*)
    raise NotImplementedError
  end

  def request_review
    raise NotImplementedError
  end

  def query
    Trends::Query.new(key_prefix, klass)
  end

  def score(id, locale: nil)
    redis.zscore([key_prefix, 'all', locale].compact.join(':'), id) || 0
  end

  def rank(id, locale: nil)
    redis.zrevrank([key_prefix, 'allowed', locale].compact.join(':'), id)
  end

  def currently_trending_ids(allowed, limit)
    redis.zrevrange(allowed ? "#{key_prefix}:allowed" : "#{key_prefix}:all", 0, limit.positive? ? limit - 1 : limit).map(&:to_i)
  end

  protected

  def key_prefix
    raise NotImplementedError
  end

  def recently_used_ids(at_time = Time.now.utc)
    redis.smembers(used_key(at_time)).map(&:to_i)
  end

  def record_used_id(id, at_time = Time.now.utc)
    redis.sadd(used_key(at_time), id)
    redis.expire(used_key(at_time), 1.day.seconds)
  end

  def score_at_rank(rank)
    redis.zrevrange("#{key_prefix}:allowed", 0, rank, with_scores: true).last&.last || 0
  end

  def replace_items(suffix, items)
    tmp_prefix    = "#{key_prefix}:tmp:#{SecureRandom.alphanumeric(6)}#{suffix}"
    allowed_items = filter_for_allowed_items(items)

    redis.pipelined do |pipeline|
      items.each { |item| pipeline.zadd("#{tmp_prefix}:all", item[:score], item[:item].id) }
      allowed_items.each { |item| pipeline.zadd("#{tmp_prefix}:allowed", item[:score], item[:item].id) }

      rename_set(pipeline, "#{tmp_prefix}:all", "#{key_prefix}:all#{suffix}", items)
      rename_set(pipeline, "#{tmp_prefix}:allowed", "#{key_prefix}:allowed#{suffix}", allowed_items)
    end
  end

  def filter_for_allowed_items(_items)
    raise NotImplementedError
  end

  private

  def used_key(at_time)
    "#{key_prefix}:used:#{at_time.beginning_of_day.to_i}"
  end

  def rename_set(pipeline, from_key, to_key, set_items)
    if set_items.empty?
      pipeline.del(to_key)
    else
      pipeline.rename(from_key, to_key)
    end
  end
end
