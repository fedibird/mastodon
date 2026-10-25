# frozen_string_literal: true

module EmojiReactionCapability
  # What the proposed rules would send for one emoji kind if the write goes
  # ahead. It ignores limits, blocks and viewer settings on purpose: the
  # legacy services send regardless of those, and shadow mode compares the
  # sending rule only.
  #
  # activity_type: 'EmojiReact', 'Like' or nil (nothing is sent)
  # audience:      :author_inbox, :receiver_inbox, :followers_and_mentions, :none
  # basis:         bounded symbol that names why (used as a metrics dimension)
  class DeliveryPlan < Data.define(:activity_type, :audience, :basis)
    ACTIVITY_TYPES = {
      native: 'EmojiReact',
      like_fallback: 'Like',
      unknown: 'Like',
      none: nil,
    }.freeze

    BASES = %i(
      native
      mechanism_override_like
      unicode_only_custom
      like_fallback
      unknown_no_row
      unknown_nodeinfo_missing
      unknown_type
      unknown_like_delivery
      unsupported_node
      unsupported_gone
      local_fanout
      author_silenced
      not_activitypub
    ).freeze

    class << self
      def for_status(status, node, kind)
        return new(activity_type: nil, audience: :none, basis: :author_silenced) if status.author_silenced
        return new(activity_type: nil, audience: :followers_and_mentions, basis: :local_fanout) if status.author_local
        return new(activity_type: nil, audience: :none, basis: :not_activitypub) unless status.author_activitypub

        for_node(node, kind, audience: :author_inbox)
      end

      def for_node(node, kind, audience: :receiver_inbox)
        mechanism, basis = Mechanism.classify(node, kind)
        new(activity_type: ACTIVITY_TYPES.fetch(mechanism), audience: audience, basis: basis)
      end
    end
  end
end
