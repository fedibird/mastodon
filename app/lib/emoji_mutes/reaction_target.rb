# frozen_string_literal: true

module EmojiMutes
  # The status a reaction row is stored on, including the one reblog step
  # EmojiReaction applies in before_validation. Canonical writes may already
  # have walked to the original. The boost author's rules are never used.
  module ReactionTarget
    module_function

    def stored_status(status)
      return nil if status.nil?

      write_status = EmojiReactionCapability::WriteTarget.resolve(status)
      return nil if write_status.nil?

      write_status.reblog? ? write_status.reblog : write_status
    end
  end
end
