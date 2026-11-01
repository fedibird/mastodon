# frozen_string_literal: true

# One explicit directory language for a group Account.
# Absence of rows means the language is unset. Do not infer a tag.
# The tag shape is GroupDirectory::Languages::PATTERN, a limited BCP 47 subset.
class GroupLanguage < ApplicationRecord
  belongs_to :account, inverse_of: :group_languages

  validates :tag, presence: true, format: { with: GroupDirectory::Languages::PATTERN }, length: { maximum: GroupDirectory::Languages::MAX_LENGTH }
  validates :account_id, uniqueness: { scope: :tag }
  validate :account_is_group

  private

  def account_is_group
    errors.add(:account, :invalid) unless account&.group?
  end
end
