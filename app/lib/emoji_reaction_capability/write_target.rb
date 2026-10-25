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
      hops = 0
      while current.reblog? && hops < MAX_REBLOG_HOPS
        current = current.proper
        hops += 1
      end
      current
    end
  end
end
