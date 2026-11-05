# frozen_string_literal: true

# scope=following without scanning the whole directory.
#
# Follow ids are loaded from PostgreSQL, then sent to Elasticsearch in
# chunks. One request never carries more than CHUNK ids. The database
# still checks that each returned id is followed now. A follow set larger
# than MAX_FOLLOW_IDS fails closed instead of issuing a bigger terms query
# or walking every group.
class GroupDirectory::FollowingSearch
  CHUNK = 500
  MAX_FOLLOW_IDS = 10_000

  def self.target_ids(viewer)
    return [] if viewer.nil?

    Follow.where(account_id: viewer.id).pluck(:target_account_id)
  end

  def initialize(viewer:, parsed:, limit:, search:, ids:)
    @viewer = viewer
    @parsed = parsed
    @limit = limit
    @search = search
    @ids = ids
  end

  def results
    return [] if @ids.empty?
    raise GroupDirectory::SearchUnavailable, 'follow set too large' if @ids.size > MAX_FOLLOW_IDS

    hits = @ids.each_slice(CHUNK).flat_map { |chunk| drain(chunk) }
    ordered = hits.sort { |left, right| compare_sort(left[:sort], right[:sort]) }
    kept = []
    ordered.map { |hit| hit[:id] }.each_slice(GroupDirectory::CandidatePage::BATCH) do |slice|
      kept.concat(GroupDirectory::Visibility.keep(viewer: @viewer, ids: slice, parsed: @parsed))
    end
    kept.drop(@parsed.offset).first(@limit)
  end

  private

  def drain(chunk)
    cursor = nil
    collected = []
    loop do
      hits = @search.call(search_after: cursor, size: GroupDirectory::CandidatePage::BATCH, extra_filter: { terms: { id: chunk } })
      break if hits.empty?

      collected.concat(hits)
      raise GroupDirectory::SearchUnavailable, 'follow chunk exceeded its ids' if collected.size > chunk.size

      cursor = hits.last[:sort]
      break if hits.size < GroupDirectory::CandidatePage::BATCH
    end
    collected
  end

  # Every directory sort is descending, and a missing value sorts last.
  def compare_sort(left, right)
    left.zip(right).each do |a, b|
      cmp = compare_value(a, b)
      return cmp unless cmp.zero?
    end
    0
  end

  def compare_value(left, right)
    return 0 if left.nil? && right.nil?
    return 1 if left.nil?
    return -1 if right.nil?

    right <=> left
  end
end
