# frozen_string_literal: true

module EmojiReactionCapability
  # Server-only switch for the fallback-policy write gate (P1b-1b).
  #
  # Same convention as WriteConfig: only the exact string "true" enables the
  # request. Enforcement also requires canonical writes and idempotent retry.
  # If either is missing, the gate stays off and the process logs one warning.
  # A partial gate would decide on a different status id than the row, or
  # would confirm a reaction and then deliver it again on retry. Leaving the
  # gate off keeps the legacy write. The process stays up so a bad combination
  # in the environment does not refuse to boot.
  module FallbackPolicyConfig
    ENFORCE_ENV = 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE'
    WARNING = '[emoji_reaction_fallback_policy] EMOJI_REACTION_FALLBACK_POLICY_ENFORCE=true but ' \
              'EMOJI_REACTION_CANONICAL_WRITES and EMOJI_REACTION_IDEMPOTENT_RETRY are not both ' \
              'true; enforcement is off'

    module_function

    def requested?
      ENV[ENFORCE_ENV].to_s == 'true'
    end

    def prerequisites_met?
      WriteConfig.canonical_writes? && WriteConfig.idempotent_retry?
    end

    def effective?
      return false unless requested?
      return true if prerequisites_met?

      warn_incomplete_once
      false
    end

    def reset_incomplete_warning!
      @incomplete_warned = false
    end

    def warn_incomplete_once
      return if @incomplete_warned

      @incomplete_warned = true
      Rails.logger.warn(WARNING)
    end
  end
end
