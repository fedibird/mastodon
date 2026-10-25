# frozen_string_literal: true

module EmojiReactionCapability
  # Viewer facts for the pure resolver. fallback_policy is an input only: P1a
  # has no stored setting, so callers pass :allow (today's behavior).
  Viewer = Data.define(:account_id, :disable_reactions, :fallback_policy) do
    def initialize(account_id: nil, disable_reactions: false, fallback_policy: :allow)
      super
    end
  end
end
