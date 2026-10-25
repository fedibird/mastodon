# frozen_string_literal: true

module EmojiReactionCapability
  # Status summary: the aggregate over both kinds plus the per-kind decisions.
  Decision = Data.define(
    :availability,
    :can_add,
    :requires_confirmation,
    :reason,
    :can_remove,
    :limit,
    :kinds
  )
end
