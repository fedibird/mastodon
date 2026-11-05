# frozen_string_literal: true

# scope=following without scanning the whole directory.
#
# Group follow ids are loaded from PostgreSQL, then read from Elasticsearch
# in chunks. The chunks are merged in sort order and visibility is checked
# only until the page is filled. One request never carries more than CHUNK
# ids. The database still checks that each returned id is followed now.
class GroupDirectory::FollowingSearch
  CHUNK = 500
  MAX_FOLLOW_IDS = 10_000
  VISIBILITY_BATCH = 100

  def self.target_ids(viewer)
    return [] if viewer.nil?

    Follow.joins(:target_account)
          .where(account_id: viewer.id, accounts: { actor_type: 'Group' })
          .limit(MAX_FOLLOW_IDS + 1)
          .pluck('follows.target_account_id')
  end

  def initialize(viewer:, parsed:, limit:, search:, ids:)
    @viewer = viewer
    @parsed = parsed
    @limit = limit
    @search = search
    @ids = ids
  end

  def results
    GroupDirectory::SearchBudget.checkpoint!
    return [] if @ids.empty?
    raise GroupDirectory::SearchUnavailable, 'follow set too large' if @ids.size > MAX_FOLLOW_IDS

    chunks = @ids.each_slice(CHUNK).map { |ids| Chunk.new(ids, @search) }
    needed = @parsed.offset + @limit
    kept = []
    batch = []
    loop do
      GroupDirectory::SearchBudget.checkpoint!
      hit, chunk = next_hit(chunks)
      break unless hit

      chunk.shift
      batch << hit[:id]
      next unless batch.size >= VISIBILITY_BATCH || kept.size + batch.size >= needed

      kept.concat(keep(batch))
      batch = []
      GroupDirectory::SearchBudget.checkpoint!
      break if kept.size >= needed
    end
    kept.concat(keep(batch)) if batch.any? && kept.size < needed
    GroupDirectory::SearchBudget.checkpoint!
    kept.drop(@parsed.offset).first(@limit)
  end

  private

  def next_hit(chunks)
    best = nil
    owner = nil
    chunks.each do |chunk|
      hit = chunk.peek
      next unless hit
      next if best && compare_sort(hit[:sort], best[:sort]) >= 0

      best = hit
      owner = chunk
    end
    [best, owner]
  end

  def keep(ids)
    GroupDirectory::Visibility.keep(viewer: @viewer, ids: ids, parsed: @parsed)
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

  # One follow chunk. The first page is loaded when the merge peeks it.
  # Later pages load only if this chunk is still needed.
  class Chunk
    def initialize(ids, search)
      @ids = ids
      @search = search
      @buffer = []
      @index = 0
      @cursor = nil
      @done = false
    end

    def peek
      load if @index >= @buffer.size && !@done
      @buffer[@index]
    end

    def shift
      hit = peek
      @index += 1 if hit
      hit
    end

    private

    def load
      return if @done

      GroupDirectory::SearchBudget.checkpoint!
      size = [@ids.size, GroupDirectory::CandidatePage::BATCH].min
      hits = @search.call(search_after: @cursor, size: size, extra_filter: { terms: { id: @ids } })
      if hits.empty?
        @done = true
        return
      end

      @buffer = hits
      @index = 0
      @cursor = hits.last[:sort]
      @done = hits.size < size || hits.size >= @ids.size
    end
  end
end
