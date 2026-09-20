# frozen_string_literal: true

# Fedibird extension for routing one upstream-compatible TagFollow to explicit
# timeline destinations.
#
# list_id = NULL => Home
# list_id = N    => List N
#
# No callback or default may create a Home row merely because TagFollow exists.
class TagFollowDelivery < ApplicationRecord
  belongs_to :tag_follow, inverse_of: :deliveries
  belongs_to :list, optional: true

  delegate :account, :account_id, :tag, :tag_id, to: :tag_follow

  scope :home, -> { where(list_id: nil) }
  scope :list, -> { where.not(list_id: nil) }
  scope :for_tags, ->(tags) { joins(:tag_follow).merge(TagFollow.where(tag: tags)) }
  scope :with_media, ->(status) { where(media_only: false) unless status&.with_media? }

  validates :tag_follow_id, uniqueness: true, if: -> { list_id.nil? }
  validates :list_id, uniqueness: { scope: :tag_follow_id }, if: -> { list_id.present? }
  validate :list_belongs_to_following_account

  private

  def list_belongs_to_following_account
    return if list.nil? || tag_follow.nil?
    return if list.account_id == tag_follow.account_id

    errors.add(:list, :invalid)
  end
end
