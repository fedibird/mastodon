# frozen_string_literal: true

module EmojiReactionCapability
  # Server-only switches for P1b-1a (canonical write target, idempotent retry).
  #
  # Same convention as ShadowConfig and MODERATION_FOLLOW_GATE_SHADOW: an
  # environment variable, read on each call, enabled only by the exact string
  # "true". Anything else, including unset, is off. There is no Setting row,
  # no migration, and no per-account value. Web processes that serve writes
  # pick the value up when they start; Sidekiq does not read these flags.
  # See docs/emoji_reaction_canonical_writes.md.
  module WriteConfig
    CANONICAL_ENV = 'EMOJI_REACTION_CANONICAL_WRITES'
    IDEMPOTENT_ENV = 'EMOJI_REACTION_IDEMPOTENT_RETRY'

    module_function

    def canonical_writes?
      ENV[CANONICAL_ENV].to_s == 'true'
    end

    def idempotent_retry?
      ENV[IDEMPOTENT_ENV].to_s == 'true'
    end
  end
end
