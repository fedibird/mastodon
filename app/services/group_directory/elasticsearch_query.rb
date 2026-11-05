# frozen_string_literal: true

# Candidate search against GroupDirectoryIndex.
#
# Filters and sort live here. Visibility and paging live in CandidatePage.
# The query is a bool filter: term filters for keywords, and match on
# text.infix for a substring. User text is never passed to query_string,
# wildcard, regexp, or a script. Blocks and mutes stay out of the query.
# FollowingSearch adds follow ids in bounded chunks. A point in time stays
# open for the whole call so search_after does not drop a group whose
# last_status_at moves between pages.
class GroupDirectory::ElasticsearchQuery
  REQUEST_TIMEOUT = '2s'
  PIT_KEEP_ALIVE = '2m'

  def initialize(viewer:, parsed:, limit:)
    @viewer = viewer
    @parsed = parsed
    @limit = limit
  end

  def results
    GroupDirectory::SearchBudget.current = GroupDirectory::SearchBudget.new
    page = search_page
    GroupDirectory::SearchBudget.checkpoint!
    page
  ensure
    GroupDirectory::SearchBudget.current = nil
    close_pit(@pit_id) if defined?(@pit_id) && @pit_id
  end

  def search_page
    if @parsed.following?
      follow_ids = GroupDirectory::FollowingSearch.target_ids(@viewer)
      GroupDirectory::SearchBudget.checkpoint!
      return [] if follow_ids.empty?
      raise GroupDirectory::SearchUnavailable, 'follow set too large' if follow_ids.size > GroupDirectory::FollowingSearch::MAX_FOLLOW_IDS
    end

    GroupDirectory::SearchBudget.checkpoint!
    @pit_id = open_pit
    GroupDirectory::SearchBudget.checkpoint!
    if @parsed.following?
      following_page(follow_ids)
    else
      GroupDirectory::CandidatePage.new(
        viewer: @viewer,
        parsed: @parsed,
        limit: @limit,
        search: method(:fetch)
      ).results
    end
  end

  def following_page(follow_ids)
    GroupDirectory::FollowingSearch.new(
      viewer: @viewer,
      parsed: @parsed,
      limit: @limit,
      search: method(:fetch),
      ids: follow_ids
    ).results
  end

  def request_body(search_after:, size:, extra_filter: nil)
    clauses = filters
    clauses << extra_filter if extra_filter
    body = {
      size: size,
      track_total_hits: false,
      timeout: REQUEST_TIMEOUT,
      _source: false,
      sort: sort_clause,
      query: { bool: { filter: clauses } },
    }
    body[:pit] = { id: @pit_id, keep_alive: PIT_KEEP_ALIVE } if @pit_id
    body[:search_after] = search_after if search_after
    body
  end

  private

  def fetch(search_after:, size:, extra_filter: nil)
    GroupDirectory::SearchBudget.current.track!
    parse_response(client_search(search_after, size, extra_filter))
  end

  def open_pit
    response = Chewy.client.open_point_in_time(index: GroupDirectoryIndex.index_name, keep_alive: PIT_KEEP_ALIVE)
    payload = response.respond_to?(:deep_stringify_keys) ? response.deep_stringify_keys : response
    id = payload['id'] if payload.is_a?(Hash)
    raise GroupDirectory::SearchUnavailable, 'point in time missing' if id.blank?

    id
  rescue GroupDirectory::SearchUnavailable
    raise
  rescue StandardError => e
    Rails.logger.error("Group directory point in time failed: #{e.class}: #{e.message.to_s.truncate(200)}")
    raise GroupDirectory::SearchUnavailable, "point in time failed: #{e.class}"
  end

  def close_pit(pit_id)
    Chewy.client.close_point_in_time(body: { id: pit_id })
  rescue StandardError => e
    Rails.logger.error("Group directory point in time close failed: #{e.class}: #{e.message.to_s.truncate(200)}")
  end

  def client_search(search_after, size, extra_filter)
    Chewy.client.search(
      body: request_body(search_after: search_after, size: size, extra_filter: extra_filter),
      allow_partial_search_results: false
    )
  rescue GroupDirectory::SearchUnavailable
    raise
  rescue StandardError => e
    Rails.logger.error("Group directory Elasticsearch query failed: #{e.class}: #{e.message.to_s.truncate(300)}")
    raise GroupDirectory::SearchUnavailable, "elasticsearch query failed: #{e.class}"
  end

  def parse_response(response)
    payload = response.respond_to?(:deep_stringify_keys) ? response.deep_stringify_keys : response
    raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch response' unless payload.is_a?(Hash)
    rotate_pit(payload)
    raise GroupDirectory::SearchUnavailable, 'elasticsearch timed out' if payload['timed_out']
    raise GroupDirectory::SearchUnavailable, 'elasticsearch shard failure' if payload.dig('_shards', 'failed').to_i.positive?

    hits = payload.dig('hits', 'hits')
    raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch response' unless hits.is_a?(Array)

    hits.map { |hit| parse_hit(hit) }
  end

  def rotate_pit(payload)
    rotated = payload['pit_id']
    @pit_id = rotated if rotated.present?
  end

  def parse_hit(hit)
    raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch hit' unless hit.is_a?(Hash)

    id = hit['_id'].to_s
    sort = hit['sort']
    unless id.match?(/\A[1-9]\d*\z/) && sort.is_a?(Array) && sort.any?
      raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch hit'
    end

    { id: id.to_i, sort: sort }
  end

  def filters
    clauses = [
      { term: { listed: true } },
      { term: { actor_type: 'Group' } },
      { bool: { must_not: [{ term: { software_bucket: 'peertube' } }] } },
    ]
    clauses.concat(exact_clauses)
    clauses << software_filter if software_filter
    clauses << language_filter if language_filter
    clauses << scope_filter if scope_filter
    clauses << substring_filter if substring_filter
    clauses
  end

  def exact_clauses
    return [] unless @parsed.exact?

    acct = @parsed.acct
    clauses = [{ term: { username: acct[:username] } }]
    clauses << { term: { domain: acct[:domain] } } if acct[:domain_constrained]
    clauses
  end

  def software_filter
    name = @parsed.software
    return if name.nil?

    case name
    when 'fedibird', 'unknown', 'other'
      { term: { software_bucket: name } }
    else
      { term: { software_name: name } }
    end
  end

  def language_filter
    case @parsed.language
    when nil
      nil
    when :unset
      { term: { languages_unset: true } }
    else
      { term: { languages: @parsed.language } }
    end
  end

  # scope=following is applied to candidate ids in Visibility. The follow
  # set is not copied into this query.
  def scope_filter
    return unless @parsed.scope == 'local'

    { term: { local: true } }
  end

  def substring_filter
    return unless @parsed.substring?

    clauses = GroupDirectory::SearchText.windows(@parsed.query).map do |window|
      { match: { 'text.infix' => { query: window } } }
    end
    return clauses.first if clauses.one?

    { bool: { filter: clauses } }
  end

  # active: last_status_at DESC NULLS LAST, id DESC. new: id DESC.
  def sort_clause
    return [{ id: { order: 'desc' } }] if @parsed.order == 'new'

    [
      { last_status_at: { order: 'desc', missing: '_last', unmapped_type: 'date' } },
      { id: { order: 'desc' } },
    ]
  end
end
