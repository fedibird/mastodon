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

  # Walk Redis in cursor order and keep only rows that still exist. A raw
  # limit of 20 can be entirely deleted, unreleased, suspended, or outside
  # visibilities; stopping there would freeze the next max_id/min_id.
  def from_redis(limit, max_id, since_id, min_id, visibilities)
    ascending = min_id.present?
    upper = max_id.presence || '+inf'
    lower = ascending ? min_id : (since_id.presence || '-inf')
    nearest = []
    scanned = 0

    while nearest.size < limit && scanned < FeedManager::MAX_ITEMS
      batch = [limit, FeedManager::MAX_ITEMS - scanned].min
      ids = raw_ids(batch, upper, lower, ascending)
      break if ids.empty?

      scanned += ids.size
      nearest.concat(selectable_ids(ids, visibilities))

      if ascending
        lower = ids.last
      else
        upper = ids.last
      end

      break if ids.size < batch
    end

    page_ids = nearest.first(limit)
    page_ids.reverse! if ascending
    records_in_order(page_ids, visibilities)
  end

  def raw_ids(batch, upper, lower, ascending)
    range = if ascending
              redis.zrangebyscore(key, "(#{lower}", "(#{upper}", limit: [0, batch], with_scores: true)
            else
              redis.zrevrangebyscore(key, "(#{upper}", "(#{lower}", limit: [0, batch], with_scores: true)
            end

    range.map(&:first).map(&:to_i)
  end

  def selectable_ids(ids, visibilities)
    present = filtered_scope(ids, visibilities).pluck(:id).to_set
    ids.select { |id| present.include?(id) }
  end

  def records_in_order(ids, visibilities)
    return [] if ids.empty?

    records = filtered_scope(ids, visibilities).index_by(&:id)
    ids.filter_map { |id| records[id] }
  end

  def filtered_scope(ids, visibilities)
    scope = Status.where(id: ids).without_unreleased_pages
    scope = scope.joins(:account).merge(Account.without_suspended)
    scope = scope.where(visibility: visibilities) unless visibilities.empty?
    scope
  end

  def key
    FeedManager.instance.key(@type, @id)
  end
end
