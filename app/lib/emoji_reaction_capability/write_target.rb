# frozen_string_literal: true

module EmojiReactionCapability
  # The one place that decides which status a reaction write is stored against.
  #
  # Flag off: the status the caller named. +Status#proper+ is not called, so a
  # boost stays a boost and the query shape of the legacy services is unchanged.
  # Flag on: walk boosts to the original. +EmojiReaction+ rewrites one reblog
  # step in +before_validation+, so stopping on an intermediate boost would make
  # the lookup id and the inserted id disagree again. +ReblogService+ already
  # collapses a boost of a boost; the hop cap only covers a hand-built chain.
  module WriteTarget
    MAX_REBLOG_HOPS = 5

    module_function

    def resolve(status)
      return status if status.nil? || !WriteConfig.canonical_writes?

      current = status
      seen = {}
      hops = 0
      while current.reblog? && hops < MAX_REBLOG_HOPS && !seen[current.id]
        seen[current.id] = true
        current = current.proper
        hops += 1
      end

      # A hop cap that stops on another boost would insert there, and
      # before_validation would move the row one step further. A cycle has
      # the same problem. Fail instead of writing that partial target.
      raise Mastodon::ValidationError, I18n.t('reactions.errors.unresolved_boost') if current.reblog?

      current
    end
  end
end
