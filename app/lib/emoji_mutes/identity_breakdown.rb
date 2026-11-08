# frozen_string_literal: true

module EmojiMutes
  # Read-only identity breakdown for caches that predate parts. It does not
  # write status_stats and does not refresh on read. One request loads the
  # missing statuses together, up to MAX_STATUSES. Beyond that cap the extra
  # statuses stay on the legacy group and are not hidden by a representative
  # domain.
  class IdentityBreakdown
    MAX_STATUSES = 80

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

        loads = EmojiMutes::Store.breakdown_loads.to_i
        if loads >= MAX_STATUSES
          store[status_id] = nil
          return nil
        end

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
        room = MAX_STATUSES - EmojiMutes::Store.breakdown_loads.to_i
        chosen = remaining.first(room)
        (remaining - chosen).each { |id| store[id] = nil }
        return if chosen.empty?

        EmojiMutes::Store.breakdown_loads = EmojiMutes::Store.breakdown_loads.to_i + chosen.size
        rows = EmojiReaction.where(status_id: chosen).includes(:custom_emoji).order(:created_at).to_a
        built = Hash.new { |hash, key| hash[key] = [] }
        rows.group_by(&:status_id).each do |status_id, reactions|
          built[status_id] = parts_by_name(reactions)
        end
        chosen.each { |id| store[id] = built.key?(id) ? built[id] : {} }
      end

      def parts_by_name(reactions)
        reactions.group_by(&:name).transform_values do |rows|
          CacheParts.parts_for_rows(rows)
        end
      end
    end
  end
end
