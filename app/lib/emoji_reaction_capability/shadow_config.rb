# frozen_string_literal: true

module EmojiReactionCapability
  # Environment-only configuration, following MODERATION_FOLLOW_GATE_SHADOW and
  # the FOLLOW_IMPORT_* flags. An environment variable is read from memory, so
  # the flag-off path costs no query, no Redis call and no Setting cache read;
  # it needs no stored setting and no migration. Changing it needs a process
  # restart, which is the intended rollout and rollback step.
  module ShadowConfig
    ENABLED_ENV = 'EMOJI_REACTION_RESOLVER_SHADOW'
    SAMPLE_RATE_ENV = 'EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE'

    DEFAULT_SAMPLE_RATE = 0.01

    # Upper bound of receivers examined per sampled fan-out. The sample is a
    # LIMIT on the same receiver set the worker already used; it is never a
    # scan of all followers.
    FANOUT_RECEIVER_SAMPLE = 50

    module_function

    def enabled?
      ENV[ENABLED_ENV].to_s == 'true'
    end

    # Unset: DEFAULT_SAMPLE_RATE. A valid number is clamped to 0..1. A value
    # that cannot be parsed fails closed (0.0, observe nothing).
    def sample_rate
      raw = ENV.fetch(SAMPLE_RATE_ENV, nil)
      return DEFAULT_SAMPLE_RATE if raw.nil? || raw.strip.empty?

      Float(raw).clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      0.0
    end

    def sample?(random: Random)
      return false unless enabled?

      rate = sample_rate
      return false unless rate.positive?

      rate >= 1.0 || random.rand < rate
    end
  end
end
