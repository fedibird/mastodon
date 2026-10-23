# frozen_string_literal: true

# Batch source membership for timeline search hits.
#
# P4b-2 contract (this endpoint does not search and does not seek):
#   POST /api/v1/timelines/membership
#   body: version, source, context (same keys as /api/v1/timelines/seek), ids
#   ids: at most MAX_IDS decimal strings. The whole call is rejected above that.
#   Search text keys (q, query, text, raw, body) are rejected and not copied
#   into this payload. GET /api/v2/search still puts `q` in the request URL,
#   so proxy and browser history can see it. This POST does not add another
#   copy, and seek still refuses raw text.
#
#   outcome complete: every id in this batch is member, not_in_source,
#     not_visible, not_found, or invalid. members is the confirmed subset,
#     newest id first. This is not a statement about the rest of the index.
#   outcome partial: at least one unknown. Home, limited, and list can only
#     confirm the Redis ZSET (FeedManager::MAX_ITEMS) for ordinary ids.
#     Outside that window is unknown, not not_in_source. Do not call the
#     range an end or "no hits". The viewer's own external projections are
#     classified from the database: a current home or list member is member,
#     and an owned projection that is not delivered to this view is
#     not_in_source (external_not_delivered). That does not delete the status.
#     A home rebuild defers eligible external ids as unknown instead of
#     treating them as the rebuilt range.
#   outcome unavailable: the source cannot be evaluated (unknown domain).
#     results is omitted.
#   outcome unsupported: closed source, version, search text, remote group,
#     too many ids, or a missing source. results is omitted.
#
#   Per id: member, not_in_source, not_visible, not_found, unknown, invalid.
#   Every candidate is preloaded (at most MAX_IDS). member requires source
#   membership AND StatusPolicy#show? AND no hide-action filter, in that
#   order. A Redis ZSET or a feed scope is not viewer authorization: a row
#   can stay in home/list or in a group scope after a block, delete, expiry,
#   visibility change, or lost group access. If show? is false the outcome is
#   not_found, including when the source still contains the id. not_found
#   also covers missing and deleted rows. It does not prove the row is
#   absent. No text or account is returned.
#   Hide-action custom filters run only after show? and source membership.
#   They become not_visible. Warn filters stay member. Mute and language
#   filters are viewer filters (not_visible) because show? is still true.
#
#   Confirmed members can be passed to POST /api/v1/timelines/seek as kind
#   status or searchHit. Seek checks again. A later miss must not rewrite
#   history. There is no response cache: blocks, mutes, and filters are read
#   for this request.
#
#   Client session caps are in `limits`. Stop at session_candidates search
#   hits, or when search is disabled / errors. An empty search page is not
#   proof of absence: StatusesSearchService turns a down index into [].
class TimelineSeek::Membership
  MAX_IDS = 50
  SESSION_CANDIDATE_LIMIT = 200
  SEARCH_PAGE_DEFAULT = 20
  SEARCH_PAGE_MAX = 40
  MAX_SEARCH_PAGES = SESSION_CANDIDATE_LIMIT / SEARCH_PAGE_DEFAULT

  Parsed = Struct.new(:ordered, :duplicates, keyword_init: true)

  def self.limits
    {
      ids: MAX_IDS,
      session_candidates: SESSION_CANDIDATE_LIMIT,
      search_page_default: SEARCH_PAGE_DEFAULT,
      search_page: SEARCH_PAGE_MAX,
      max_search_pages: MAX_SEARCH_PAGES,
    }
  end

  def initialize(account, user: nil, application: nil)
    @account = account
    @user = user
    @application = application
  end

  def call(payload)
    with_aligned_viewer do
      classify_call(payload)
    end
  end

  private

  def classify_call(payload)
    payload ||= {}
    @source = payload[:source].to_s
    return halt('unsupported', 'search_text_not_accepted') if payload[:reject_search_text] || search_text?(payload)
    return halt('unsupported', 'version') unless payload[:version].to_i == TimelineSeek::Capability::VERSION

    entry = TimelineSeek::Capability.lookup(@source, 'membership')
    return halt('unsupported', entry.reason, capability: entry.level) unless supported_level?(entry)

    parsed = parse_ids(payload[:ids])
    return parsed if parsed.is_a?(TimelineSeek::MembershipResult)

    reader = resolver.open_reader(@source, payload[:context])
    return from_reader(reader) if reader.is_a?(TimelineSeek::Result)

    classify(entry, reader, parsed)
  end

  def resolver
    TimelineSeek::Resolver.new(@account, user: @user, application: @application)
  end

  def with_aligned_viewer
    viewer = ExternalBridge::Viewer.user_id
    aligned = @user.present? && (viewer.nil? || viewer == @user.id)
    ExternalBridge::Viewer.with_user(aligned ? @user.id : nil) do
      yield
    end
  end

  def supported_level?(entry)
    entry.level == 'supported' || entry.level == 'approximate'
  end

  def halt(outcome, reason, capability: 'unsupported', limitations: [])
    TimelineSeek::MembershipResult.halt(source: @source, outcome: outcome, capability: capability, reason: reason, limitations: limitations)
  end

  def from_reader(result)
    halt(result.outcome, result.reason, capability: result.capability, limitations: result.limitations)
  end

  def search_text?(value)
    case value
    when Hash
      value.keys.any? { |key| TimelineSeek::Resolver::SEARCH_TEXT_KEYS.include?(key.to_s) } || value.values.any? { |child| search_text?(child) }
    when Array
      value.any? { |child| search_text?(child) }
    else
      false
    end
  end

  def parse_ids(raw)
    return halt('unsupported', 'missing_ids') if raw.nil? || (raw.is_a?(Array) && raw.empty?)
    return halt('unsupported', 'invalid_ids') unless raw.is_a?(Array)
    return halt('unsupported', 'too_many_ids') if raw.size > MAX_IDS

    ordered = []
    seen = {}
    duplicates = false
    raw.each do |value|
      integer = TimelineSeek::StatusId.parse(value)
      if integer && seen[integer]
        duplicates = true
        next
      end

      seen[integer] = true if integer
      ordered << { id: integer, text: integer&.to_s }
    end
    Parsed.new(ordered: ordered, duplicates: duplicates)
  end

  def classify(entry, reader, parsed)
    batch = batch_for(reader, parsed)
    rows = parsed.ordered.map { |row| build_row(row, batch) }
    outcome = rows.any? { |row| row.outcome == 'unknown' } ? 'partial' : 'complete'
    TimelineSeek::MembershipResult.classified(
      source: @source,
      outcome: outcome,
      capability: entry.level,
      limitations: limitations_for(reader, parsed),
      results: rows
    )
  end

  # Source membership is checked for the whole id set, then show? is applied
  # to every loaded row. Hide filters see only ids that passed both.
  def batch_for(reader, parsed)
    ids = parsed.ordered.filter_map { |row| row[:id] }
    retained = reader.redis? ? reader.retained_ids(ids).to_set : Set.new
    filtered = filtered_ids(reader, ids, retained)
    partition = reader.external_partition(ids)
    filtered.merge(partition.members)
    records = load_records(ids)
    maps = relation_maps(records.values)
    visible = visible_ids(records, maps, status_maps(records.values))
    confirmed = filtered & visible
    hidden = TimelineSeek::HideFilter.new(@account, @source).hidden_ids(confirmed.to_a).to_set
    unfiltered = unfiltered_ids(reader, (visible - filtered).to_a)
    unloaded = unloaded_remote_ids(reader, ids, records)

    {
      reader: reader,
      filtered: filtered,
      hidden: hidden,
      visible: visible,
      unfiltered: unfiltered,
      retained: retained,
      unloaded: unloaded,
      withheld: partition.withheld,
      deferred: partition.deferred,
    }
  end

  # Remote account posts that are not in this database are unknown. A discarded
  # row still exists, so a delete stays not_found instead of not_loaded.
  def unloaded_remote_ids(reader, ids, records)
    return Set.new unless reader.respond_to?(:remote_account?) && reader.remote_account?

    missing = ids.reject { |id| records.key?(id) }
    return Set.new if missing.empty?

    stored = Status.unscoped.where(id: missing).pluck(:id)
    (missing - stored).to_set
  end

  def filtered_ids(reader, ids, retained)
    return Set.new if ids.empty?

    if reader.redis?
      reader.selectable_among(retained.to_a, limit: MAX_IDS).to_set
    else
      reader.scope_ids(ids, limit: MAX_IDS).to_set
    end
  end

  def unfiltered_ids(reader, ids)
    return Set.new if ids.empty? || reader.redis? || reader.unfiltered.nil?

    reader.unfiltered.scope_ids(ids, limit: MAX_IDS).to_set
  end

  def load_records(ids)
    return {} if ids.empty?

    # include_expired keeps an owner's expired personal row visible to policy.
    # discarded rows stay out, so a delete is not_found.
    Status.include_expired.where(id: ids).includes(:account, :mentions).index_by(&:id)
  end

  def relation_maps(records)
    return {} if @account.nil? || records.empty?

    author_ids = records.map(&:account_id).uniq
    followed = Follow.where(account_id: @account.id, target_account_id: author_ids).pluck(:target_account_id)
    blocked = Block.where(account_id: author_ids, target_account_id: @account.id).pluck(:account_id)
    domains = @account.domain_blocks.pluck(:domain)
    domain_map = {}
    records.each do |record|
      domain = record.account&.domain
      domain_map[record.account_id] = domain.present? && domains.include?(domain)
    end
    {
      following: followed.index_with { true },
      blocked_by: blocked.index_with { true },
      domain_blocking_by_domain: domain_map,
    }
  end

  # Expired rows consult favourites, bookmarks, and reactions inside show?.
  # Load those maps once. Fresh public rows never reach that branch.
  def status_maps(records)
    expired = records.select(&:expired?)
    return {} if @account.nil? || expired.empty?

    ids = expired.flat_map { |record| [record.id, record.reblog_of_id] }.compact.uniq
    {
      favourites_map: Status.favourites_map(ids, @account.id),
      bookmarks_map: Status.bookmarks_map(ids, @account.id),
      emoji_reactions_map: Status.emoji_reactions_map(ids, @account.id),
    }
  end

  def visible_ids(records, maps, status_maps)
    ExternalBridge::ProjectionAccess.prepare!(records.values)
    records.each_with_object(Set.new) do |(id, record), visible|
      visible << id if StatusPolicy.new(@account, record, maps, status_maps).show?
    end
  end

  def build_row(row, batch)
    return TimelineSeek::MembershipResult::Row.new(outcome: 'invalid', reason: 'invalid_id') if row[:id].nil?

    id = row[:id]
    text = row[:text]
    return row_for(text, 'unknown', 'not_loaded') if batch[:unloaded]&.include?(id)
    return row_for(text, 'not_found') unless batch[:visible].include?(id)

    if batch[:filtered].include?(id)
      return row_for(text, 'not_visible', 'viewer_filter') if batch[:hidden].include?(id)

      return row_for(text, 'member')
    end

    if batch[:deferred]&.include?(id)
      return row_for(text, 'unknown', 'feed_regenerating')
    end

    if batch[:withheld]&.include?(id)
      return row_for(text, 'not_in_source', 'external_not_delivered')
    end

    if batch[:reader].redis?
      return row_for(text, 'not_in_source', 'source_filter') if batch[:retained].include?(id)

      reason = batch[:reader].regenerating? ? 'feed_regenerating' : 'outside_retained_range'
      return row_for(text, 'unknown', reason)
    end

    if batch[:unfiltered].include?(id)
      row_for(text, 'not_visible', 'viewer_filter')
    else
      row_for(text, 'not_in_source')
    end
  end

  def row_for(id, outcome, reason = nil)
    TimelineSeek::MembershipResult::Row.new(id: id, outcome: outcome, reason: reason)
  end

  def limitations_for(reader, parsed)
    list = []
    list << "retention_#{FeedManager::MAX_ITEMS}" if reader.redis?
    list << 'external_db_membership' if reader.external?
    list << 'feed_regenerating' if reader.regenerating?
    list << 'duplicate_ids' if parsed.duplicates
    list
  end
end
