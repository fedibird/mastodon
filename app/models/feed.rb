# frozen_string_literal: true

class Feed
  include Redisable

  def initialize(type, id)
    @type = type
    @id   = id
  end

  CandidateScan = Struct.new(:ids, :exhausted, :ascending, :frontier_id, :scanned, keyword_init: true)

  def get(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
    visibilities = [] if visibilities.nil?
    scan = candidate_scan(limit, max_id, since_id, min_id, visibilities)
    ids = scan.ids.dup
    ids.reverse! if scan.ascending
    records_in_order(ids, visibilities)
  end

  # Selectable ids in redis walk order. exhausted is true only when this
  # cursor range was read to the end. frontier_id is the last raw id examined.
  # A caller merging another id source must not step past that frontier unless
  # the redis range is exhausted. min_id walks ascending; every other cursor
  # walks descending. The response order of get is still newest first.
  def candidate_scan(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
    limit    = limit.to_i
    max_id   = max_id.to_i if max_id.present?
    since_id = since_id.to_i if since_id.present?
    min_id   = min_id.to_i if min_id.present?
    visibilities = [] if visibilities.nil?

    ascending = min_id.present?
    upper = max_id.presence || '+inf'
    lower = ascending ? min_id : (since_id.presence || '-inf')
    nearest = []
    scanned = 0
    width = limit
    frontier = nil
    exhausted = false

    while nearest.size < limit && scanned < FeedManager::MAX_ITEMS
      batch = [width, FeedManager::MAX_ITEMS - scanned].min
      ids = raw_ids(batch, upper, lower, ascending)
      if ids.empty?
        exhausted = true
        break
      end

      scanned += ids.size
      frontier = ids.last
      nearest.concat(selectable_ids(ids, visibilities))
      width = [width * 2, 160].min

      if ascending
        lower = ids.last
      else
        upper = ids.last
      end

      if ids.size < batch
        exhausted = true
        break
      end
    end

    CandidateScan.new(ids: nearest.first(limit), exhausted: exhausted, ascending: ascending, frontier_id: frontier, scanned: scanned)
  end

  def records_for(ids, visibilities = [])
    records_in_order(Array(ids), visibilities || [])
  end

  protected

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
    scope = Status.where(id: ids).without_unreleased_pages.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL))
    scope = scope.joins(:account).merge(Account.without_suspended)
    scope = scope.where(visibility: visibilities) unless visibilities.empty?
    scope
  end

  def key
    FeedManager.instance.key(@type, @id)
  end
end
