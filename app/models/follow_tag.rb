# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_tags
#
#  id         :bigint(8)        not null, primary key
#  account_id :bigint(8)
#  tag_id     :bigint(8)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint(8)
#  media_only :boolean          default(FALSE), not null
#

class FollowTag < ApplicationRecord
  include RateLimitable
  include Paginable

  belongs_to :account, inverse_of: :follow_tags, required: true
  belongs_to :tag, inverse_of: :follow_tags, required: true
  belongs_to :list, optional: true

  delegate :name, to: :tag, allow_nil: true

  validates_associated :tag, on: :create
  validates :name, presence: true, on: :create
  validates :account_id, uniqueness: { scope: [:tag_id, :list_id] }

  scope :home, -> { where(list_id: nil) }
  scope :list, -> { where.not(list_id: nil) }
  scope :with_media, ->(status) { where(media_only: false) unless status.with_media? }

  accepts_nested_attributes_for :tag

  rate_limit by: :account, family: :follows

  after_save :mirror_tag_follow_relation
  after_destroy :mirror_destroyed_tag_follow_relation

  def name=(str)
    self.tag = Tag.find_or_create_by_names(str.strip)&.first
  end

  private

  def mirror_tag_follow_relation
    mirror_previous_tag_follow_relation if saved_change_to_account_id? || saved_change_to_tag_id?
    mirror_tag_follow_relation_for(account_id, tag_id)
  end

  def mirror_destroyed_tag_follow_relation
    mirror_tag_follow_relation_for(account_id, tag_id)
  end

  def mirror_previous_tag_follow_relation
    previous_account_id = saved_change_to_account_id&.first || account_id
    previous_tag_id = saved_change_to_tag_id&.first || tag_id

    mirror_tag_follow_relation_for(previous_account_id, previous_tag_id)
  end

  def mirror_tag_follow_relation_for(mirror_account_id, mirror_tag_id)
    return if mirror_account_id.nil? || mirror_tag_id.nil?

    HashtagUnification::FollowTagMirror.new(
      account_id: mirror_account_id,
      tag_id: mirror_tag_id
    ).call
  end
end
