# frozen_string_literal: true

# The ordered definition is deliberately separate from the resolved picker
# stock. Missing/disabled custom emoji remain in this document, by database ID.
class PersonalEmojiSet < ApplicationRecord
  belongs_to :user, inverse_of: :personal_emoji_set

  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
