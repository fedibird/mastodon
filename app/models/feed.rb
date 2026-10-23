# frozen_string_literal: true

class Feed
  include Redisable

  def initialize(type, id)
    @type = type
    @id   = id
  end

  CandidateScan = Struct.new(:ids, :exhausted, :ascending, :frontier_id, :scanned, keyword_init: true)

  # Redis ZSET scores are IEEE doubles. Integer scores are exact only through
  # ±2^53 (https://redis.io/docs/latest/commands/zadd/). One score can hold
  # many bigint members. 4096 is above the widest gap a signed bigint score
  # can collapse, so one score read is the whole bucket.
  SCORE_BUCKET_LIMIT = 4096

  def get(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
    visibilities = [] if visibilities.nil?
    scan = candidate_scan(limit, max_id, since_id, min_id, visibilities)
    ids = scan.ids.dup
    ids.reverse! if scan.ascending
    records_in_order(ids, visibilities)
  end

  # Selectable ids in redis walk order. exhausted is true when this cursor
  # range was read to the end, including a budget that lands on the last
  # member. frontier_id is the last raw integer id examined. A caller merging
  # another id source must not step past that frontier unless the redis range
  # is exhausted. min_id walks ascending; every other cursor walks descending.
  # The response order of get is still newest first.
  #
  # Bounds are exclusive integer member ids. The Redis read is widened to the
  # inclusive score of that integer, then the original member id decides what
  # belongs on this page. A score bucket is read in full before the limit cuts
  # it, so a refill that stops inside the bucket does not drop the unread
  # members. The next walk continues from the last integer id returned.
  def candidate_scan(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
    limit    = limit.to_i
    max_id   = max_id.to_i if max_id.present?
    since_id = since_id.to_i if since_id.present?
    min_id   = min_id.to_i if min_id.present?
    visibilities = [] if visibilities.nil?

    ascending = min_id.present?
    # Stored external rows are visibility 201. An external-only filter cannot
    # match an ordinary feed member, so the ordinary range is already exhausted.
    if external_only_visibility?(visibilities)
      return CandidateScan.new(ids: [], exhausted: true, ascending: ascending, frontier_id: nil, scanned: 0)
    end

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

    # A full last batch used to leave exhausted false even when that batch was
    # the end of the key. One more integer read distinguishes "the range ended"
    # from "unconfirmed ordinary members remain past the budget". The probe id
    # stays unread: the frontier does not move.
    if !exhausted && nearest.size < limit && scanned >= FeedManager::MAX_ITEMS && raw_ids(1, upper, lower, ascending).empty?
      exhausted = true
    end

    CandidateScan.new(ids: nearest.first(limit), exhausted: exhausted, ascending: ascending, frontier_id: frontier, scanned: scanned)
  end

  def records_for(ids, visibilities = [])
    records_in_order(Array(ids), visibilities || [])
  end

  protected

  def raw_ids(batch, upper, lower, ascending)
    return [] if batch <= 0

    upper_id = bound_integer(upper)
    lower_id = bound_integer(lower)
    redis_max = upper_id.nil? ? '+inf' : upper_id.to_s
    redis_min = lower_id.nil? ? '-inf' : lower_id.to_s
    collected = []

    16.times do
      break if collected.size >= batch

      need = batch - collected.size
      rows = score_range(redis_max, redis_min, need, ascending)
      break if rows.empty?

      truncated = rows.size >= need
      score = rows.last[1]
      if truncated
        head = rows.take_while { |_, row_score| row_score != score }
        rows = head + members_at_score(score, ascending)
      end

      picked = in_range_ids(rows, upper_id, lower_id, ascending) - collected
      room = batch - collected.size
      collected.concat(picked.first(room))
      break if picked.size > room
      break unless truncated

      advanced = exclusive_score_bound(score)
      if ascending
        break if advanced == redis_min

        redis_min = advanced
      else
        break if advanced == redis_max

        redis_max = advanced
      end
    end

    collected
  end

  def external_only_visibility?(visibilities)
    list = Array(visibilities).map { |value| value.to_s.strip }.reject(&:empty?)
    list.any? && list.all? { |value| value == 'external' }
  end

  def bound_integer(value)
    return nil if value.nil? || value == '+inf' || value == '-inf'

    value.to_i
  end

  def score_range(redis_max, redis_min, limit, ascending)
    if ascending
      redis.zrangebyscore(key, redis_min, redis_max, limit: [0, limit], with_scores: true)
    else
      redis.zrevrangebyscore(key, redis_max, redis_min, limit: [0, limit], with_scores: true)
    end
  end

  def members_at_score(score, ascending)
    bound = integer_score(score).to_s
    score_range(bound, bound, SCORE_BUCKET_LIMIT, ascending)
  end

  def exclusive_score_bound(score)
    "(#{integer_score(score)}"
  end

  def integer_score(score)
    score.to_i
  end

  def in_range_ids(rows, upper_id, lower_id, ascending)
    ids = rows.map { |member, _score| member.to_i }
    ids.select! { |id| upper_id.nil? || id < upper_id }
    ids.select! { |id| lower_id.nil? || id > lower_id }
    ids.uniq!
    ids.sort!
    ids.reverse! unless ascending
    ids
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
