# frozen_string_literal: true

module EmojiMutes
  # Read-only identity breakdown for caches that predate parts. It does not
  # write status_stats and does not refresh on read. Every status that still
  # needs parts is loaded. SQL is chunked so one request does not issue one
  # query per post or an unbounded IN list. Exceeding a chunk never skips a
  # mute.
  class IdentityBreakdown
    QUERY_BATCH = 200

    class << self
      def prepare(statuses, user)
        rules = RuleSet.for_user(user)
        return unless rules.hide_any?

        ids = Array(statuses).flat_map { |status| [status, status.try(:reblog)] }.compact.uniq(&:id).select { |status| needs_parts?(status) }.map(&:id)
        load(ids)
      end

      def for_status(status_id)
        store = EmojiMutes::Store.breakdowns ||= {}
        return store[status_id] if store.key?(status_id)

        load([status_id])
        store[status_id]
      end

      def needs_parts?(status)
        groups = ReactionProjection.parse(status.status_stat&.emoji_reactions_cache)
        groups.any? { |group| !group['parts'].is_a?(Array) && !ReactionProjection.unicode_only?(group) }
      end

      def load(status_ids)
        store = EmojiMutes::Store.breakdowns ||= {}
        remaining = status_ids.map(&:to_i).uniq.reject { |id| store.key?(id) }
        return if remaining.empty?

        remaining.each_slice(QUERY_BATCH) do |slice|
          rows = EmojiReaction.where(status_id: slice).includes(:custom_emoji).order(:created_at).to_a
          grouped = rows.group_by(&:status_id)
          slice.each { |id| store[id] = parts_by_name(grouped[id] || []) }
        end
      end

      def parts_by_name(reactions)
        reactions.group_by(&:name).transform_values do |rows|
          CacheParts.parts_for_rows(rows)
        end
      end
    end
  end
end
