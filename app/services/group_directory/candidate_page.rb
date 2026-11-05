# frozen_string_literal: true

# Turns an Elasticsearch candidate stream into one directory page.
#
# Offset and limit apply after Visibility keeps a row, not to the raw
# index page. search_after walks forward inside the point in time opened
# by ElasticsearchQuery, so a last_status_at change during the walk cannot
# move an unseen group behind the cursor. The scan stops at MAX_SCAN, and
# ElasticsearchQuery also stops after SearchBudget::MAX_CALLS searches or
# SearchBudget::MAX_ELAPSED seconds. Either limit raises instead of
# returning a short page.
# Spending that budget before the page is filled, while the index still
# has another hit, raises SearchUnavailable. A short page is returned
# only when the index itself has no further hit. The response is never a
# quietly truncated page.
class GroupDirectory::CandidatePage
  BATCH = 500
  # MAX_OFFSET + the API's largest limit (40 * 2) still fits, with room
  # for candidates the database then drops. Past this, fail closed.
  MAX_SCAN = GroupDirectory::Query::MAX_OFFSET + 2_000

  def initialize(viewer:, parsed:, limit:, search:)
    @viewer = viewer
    @parsed = parsed
    @limit = limit
    @search = search
    @seen = {}
  end

  def results
    visible = []
    cursor = nil
    scanned = 0
    exhausted = false
    needed = @parsed.offset + @limit

    while visible.size < needed && !exhausted && scanned < MAX_SCAN
      size = [BATCH, MAX_SCAN - scanned].min
      hits = @search.call(search_after: cursor, size: size)
      if hits.empty?
        exhausted = true
        break
      end

      fresh = unseen(hits)
      raise GroupDirectory::SearchUnavailable, 'repeated elasticsearch page' if fresh.empty?

      scanned += hits.size
      visible.concat(GroupDirectory::Visibility.keep(viewer: @viewer, ids: fresh.map { |hit| hit[:id] }, parsed: @parsed))
      cursor = hits.last[:sort]
      exhausted = hits.size < size
    end

    raise_cap!(scanned) if visible.size < needed && !exhausted && more_after?(cursor)

    page = visible.drop(@parsed.offset).first(@limit)
    ActiveSupport::Notifications.instrument('group_directory.elasticsearch_search', scanned: scanned, returned: page.size)
    page
  end

  private

  def unseen(hits)
    fresh = []
    hits.each do |hit|
      next if @seen[hit[:id]]

      @seen[hit[:id]] = true
      fresh << hit
    end
    fresh
  end

  # One probe distinguishes "the index ended on the scan boundary" from
  # "another candidate exists past the budget". The probe is not returned.
  def more_after?(cursor)
    return true if cursor.nil?

    @search.call(search_after: cursor, size: 1).any?
  end

  def raise_cap!(scanned)
    Rails.logger.error("Group directory Elasticsearch scan stopped after #{scanned} candidates (limit #{MAX_SCAN})")
    raise GroupDirectory::SearchUnavailable, 'candidate scan limit'
  end
end
