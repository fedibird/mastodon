# frozen_string_literal: true

class Feed
  include Redisable

  def initialize(type, id)
    @type = type
    @id   = id
  end

  def get(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
    limit    = limit.to_i
    max_id   = max_id.to_i if max_id.present?
    since_id = since_id.to_i if since_id.present?
    min_id   = min_id.to_i if min_id.present?

    from_redis(limit, max_id, since_id, min_id, visibilities)
  end

  protected

  def from_redis(limit, max_id, since_id, min_id, visibilities)
    unhydrated, ascending = redis_status_ids(limit, max_id, since_id, min_id, visibilities)
    scope = Status.where(id: unhydrated).without_unreleased_pages
    scope = scope.joins(:account).merge(Account.without_suspended)
    return scope if visibilities.empty?

    # Status.recent is id DESC. limit() on the whole Redis scan therefore
    # keeps the largest ids, not the ids next to min_id. Walk the Redis
    # order so a visibility filter stays contiguous with the cursor.
    visible_ids = scope.where(visibility: visibilities).pluck(:id).to_set
    nearest = unhydrated.select { |id| visible_ids.include?(id) }.first(limit)
    page_ids = ascending ? nearest.reverse : nearest
    records = scope.where(visibility: visibilities).where(id: page_ids).index_by(&:id)

    page_ids.filter_map { |id| records[id] }
  end

  def redis_status_ids(limit, max_id, since_id, min_id, visibilities)
    max_id = '+inf' if max_id.blank?
    scan_limit = visibilities.empty? ? limit : FeedManager::MAX_ITEMS

    if min_id.blank?
      since_id = '-inf' if since_id.blank?
      ids = redis.zrevrangebyscore(key, "(#{max_id}", "(#{since_id}", limit: [0, scan_limit], with_scores: true)
      return [ids.map(&:first).map(&:to_i), false]
    end

    ids = redis.zrangebyscore(key, "(#{min_id}", "(#{max_id}", limit: [0, scan_limit], with_scores: true)
    [ids.map(&:first).map(&:to_i), true]
  end

  def key
    FeedManager.instance.key(@type, @id)
  end
end
