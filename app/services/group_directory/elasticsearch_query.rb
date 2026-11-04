# frozen_string_literal: true

# Candidate search against GroupDirectoryIndex.
#
# Filters and sort live here. Visibility and paging live in CandidatePage.
# The query is a bool filter: term filters for keywords, and match on
# text.infix for a substring. User text is never passed to query_string,
# wildcard, regexp, or a script. Follows, blocks, and mutes are not terms
# in this request.
class GroupDirectory::ElasticsearchQuery
  REQUEST_TIMEOUT = '2s'

  def initialize(viewer:, parsed:, limit:)
    @viewer = viewer
    @parsed = parsed
    @limit = limit
  end

  def results
    GroupDirectory::CandidatePage.new(
      viewer: @viewer,
      parsed: @parsed,
      limit: @limit,
      search: method(:fetch)
    ).results
  end

  def request_body(search_after:, size:)
    body = {
      size: size,
      track_total_hits: false,
      timeout: REQUEST_TIMEOUT,
      _source: false,
      sort: sort_clause,
      query: { bool: { filter: filters } },
    }
    body[:search_after] = search_after if search_after
    body
  end

  private

  def fetch(search_after:, size:)
    parse_response(client_search(search_after, size))
  end

  def client_search(search_after, size)
    Chewy.client.search(index: GroupDirectoryIndex.index_name, body: request_body(search_after: search_after, size: size))
  rescue StandardError => e
    Rails.logger.error("Group directory Elasticsearch query failed: #{e.class}: #{e.message.to_s.truncate(300)}")
    raise GroupDirectory::SearchUnavailable, "elasticsearch query failed: #{e.class}"
  end

  def parse_response(response)
    payload = response.respond_to?(:deep_stringify_keys) ? response.deep_stringify_keys : response
    raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch response' unless payload.is_a?(Hash)
    raise GroupDirectory::SearchUnavailable, 'elasticsearch timed out' if payload['timed_out']

    hits = payload.dig('hits', 'hits')
    raise GroupDirectory::SearchUnavailable, 'malformed elasticsearch response' unless hits.is_a?(Array)

    hits.map { |hit| parse_hit(hit) }
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
