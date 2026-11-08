# frozen_string_literal: true

module EmojiMutes
  # Reject uses the local author of the status the row is stored on.
  # A remote author is never guessed. hide_reactions is not consulted here.
  module ReactionPolicy
    module_function

    def reject_new?(stored_status, identity)
      return false if stored_status.nil? || identity.nil?

      author = stored_status.account
      return false unless author&.local?

      RuleSet.for_user(author.user).rejects_reaction?(identity)
    end

    def suppress_existing?(reaction, _request_identity = nil)
      return false if reaction.nil?

      reject_new?(reaction.status, Identity.for_reaction(reaction))
    end
  end
end
