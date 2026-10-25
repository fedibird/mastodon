# frozen_string_literal: true

module EmojiReactionCapability
  # Normalized, read-only view of one Node for emoji reaction decisions
  # (docs/emoji_reaction_capability_resolver.md section 5.1.1).
  #
  # Node#info is heterogeneous (booleans, 'none', missing keys). This is the
  # only place that reads those raw values. Precedence per field, first match
  # wins:
  #   1. a key present in info_override (admin) decides and is known
  #   2. NodeInfo missing (or no row): the field is unknown, and a value that
  #      is still in info is ignored as stale
  #   3. otherwise the value in info, normalized
  #
  # type_source records which rule decided emoji_reaction_type:
  #   :override, :info, :missing_nodeinfo, :no_row
  class NodeSnapshot < Data.define(
    :row_present,
    :software,
    :upstream,
    :emoji_reaction_type,
    :type_source,
    :like_delivery,
    :max_per_account,
    :reachability,
    :mechanism_override,
    :nodeinfo_missing,
    :admin_override,
    :stale_info_ignored,
    :stale
  )
    DEFAULT_STALE_AFTER = 30.days
    EMOJI_TYPES = %w(custom unicode none).freeze
    LIKE_ACCEPTS = [true, 'public', 'true'].freeze
    KNOWN_FAMILIES = %w(mastodon fedibird pleroma akkoma gotosocial pixelfed friendica).freeze

    class << self
      def absent
        new(
          row_present: false,
          software: nil,
          upstream: nil,
          emoji_reaction_type: 'unknown',
          type_source: :no_row,
          like_delivery: :unknown,
          max_per_account: nil,
          reachability: :unknown,
          mechanism_override: nil,
          nodeinfo_missing: true,
          admin_override: false,
          stale_info_ignored: false,
          stale: false
        )
      end

      # info and info_override are the raw JSONB values (anything may be nil or
      # not a Hash). nodeinfo_missing is the database expression
      # `nodeinfo IS NULL OR nodeinfo->>'error' = 'missing'`, so the large
      # nodeinfo JSON never has to be loaded.
      def from_attributes(info:, info_override:, nodeinfo_missing:, status:, last_fetched_at:, now:, stale_after: DEFAULT_STALE_AFTER) # rubocop:disable Metrics/ParameterLists
        info      = hash_or_empty(info)
        override  = hash_or_empty(info_override)
        missing   = nodeinfo_missing ? true : false
        resolve   = ->(key) { resolve_field(key, info, override, missing) }

        raw_type, type_source = resolve.call('emoji_reaction_type')
        type                  = normalize_type(raw_type)
        raw_like              = resolve.call('favourite').first
        raw_max               = resolve.call('emoji_reaction_max').first
        software              = normalize_name(resolve.call('software_name').first)

        new(
          row_present: true,
          software: software,
          upstream: normalize_name(resolve.call('upstream_name').first),
          emoji_reaction_type: type,
          type_source: type_source,
          like_delivery: normalize_like(raw_like),
          max_per_account: normalize_max(raw_max, type),
          reachability: normalize_reachability(status),
          mechanism_override: software == 'kmyblue' ? :like_fallback : nil,
          nodeinfo_missing: missing,
          admin_override: override.any?,
          stale_info_ignored: stale_info_ignored?(info, override, missing),
          stale: last_fetched_at.nil? || last_fetched_at <= now - stale_after
        )
      end

      def normalize_type(raw)
        EMOJI_TYPES.include?(raw) ? raw : 'unknown'
      end

      def normalize_like(raw)
        if LIKE_ACCEPTS.include?(raw)
          :accepts
        elsif raw == 'none'
          :rejects
        else
          # false is the misskey-family inference: no favourite concept, but a
          # Like is still received as a reaction. It is not a rejection.
          :unknown
        end
      end

      def normalize_max(raw, normalized_type)
        return unless raw.is_a?(Integer)
        return raw if raw.positive?

        raw.zero? && normalized_type == 'none' ? 0 : nil
      end

      def normalize_reachability(status)
        case status.to_s
        when 'gone' then :gone
        when 'up' then :up
        else :unknown
        end
      end

      private

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end

      def resolve_field(key, info, override, missing)
        return [override[key], :override] if override.key?(key)
        return [nil, :missing_nodeinfo] if missing

        [info[key], :info]
      end

      def normalize_name(raw)
        raw.is_a?(String) && raw.present? ? raw.downcase : nil
      end

      def stale_info_ignored?(info, override, missing)
        missing && !override.key?('emoji_reaction_type') && EMOJI_TYPES.include?(info['emoji_reaction_type'])
      end
    end

    def known?
      emoji_reaction_type != 'unknown'
    end

    # Bounded label for metrics. Never the raw software name.
    def family
      names = [software, upstream].compact
      return 'birdsitelive' if names.include?('birdsitelive')
      return 'kmyblue' if names.include?('kmyblue')
      return 'misskey' if names.include?('misskey')

      found = names.find { |name| KNOWN_FAMILIES.include?(name) }
      return found if found

      names.empty? ? 'unknown' : 'other'
    end

    # Bounded label: why a type is or is not known.
    def state
      if !row_present
        'no_row'
      elsif type_source == :missing_nodeinfo
        'nodeinfo_missing'
      elsif !known?
        'unknown_type'
      else
        'known'
      end
    end
  end
end
