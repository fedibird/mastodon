# frozen_string_literal: true

module EmojiReactionCapability
  # The viewer's reaction rows on the canonical status, split by delivery
  # mechanism (docs/emoji_reaction_capability_resolver.md section 4).
  #
  # nil means "not read". Without the emoji_reactions.delivery_mechanism column
  # (P1a) the native/fallback split of existing rows is unknown, so
  # .legacy(total) reports every row as unknown and no target limit is ever
  # enforced from it.
  Counts = Data.define(:total, :native, :unknown) do
    def self.legacy(total)
      new(total: total, native: 0, unknown: total)
    end

    def self.unavailable
      new(total: nil, native: nil, unknown: nil)
    end
  end
end
