# frozen_string_literal: true

# A named reading place for one signed-in user.
#
# Server rows are the store. A browser copy would not follow the account
# across devices, and it would survive on a shared browser after sign-out.
# User preferences are a scalar settings document, markers are one read id
# for home/notifications, and status bookmarks collect posts. None of those
# is a list of named timeline anchors.
#
# The row stores the source, its allowlisted context, and one logical anchor
# (status id, display row, pixel offset, alignment). It does not store status
# text, search queries, tokens, or a timeline window.
#
# == Schema Information
#
# Table name: timeline_reading_bookmarks
#
#  id               :bigint(8)        not null, primary key
#  user_id          :bigint(8)        not null
#  name             :string(100)      not null
#  source           :string(16)       not null
#  context          :jsonb            not null
#  anchor_version   :integer          default(1), not null
#  anchor_status_id :string(19)       not null
#  display_row_id   :string(128)
#  offset_px        :integer          not null
#  alignment        :string(8)        not null
#  captured_at      :datetime
#  lock_version     :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class TimelineReadingBookmark < ApplicationRecord
  PER_USER_LIMIT = 50
  NAME_MAX_LENGTH = 100
  CONTEXT_MAX_BYTES = 2048
  OFFSET_RANGE = -1_000_000..1_000_000
  SOURCES = %w(
    home
    limited
    list
    hashtag
    public
    domain
    group
    personal
  ).freeze
  ALIGNMENTS = %w(top center).freeze

  belongs_to :user, inverse_of: :timeline_reading_bookmarks

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }, uniqueness: { scope: :user_id }
  validates :source, inclusion: { in: SOURCES }
  validates :alignment, inclusion: { in: ALIGNMENTS }
  validates :anchor_version, inclusion: { in: [1] }
  validates :offset_px, inclusion: { in: OFFSET_RANGE }
  validate :name_is_stripped_text
  validate :anchor_status_is_decimal
  validate :context_is_bounded_hash
  validate :within_user_limit, on: :create

  def source_timeline_id
    TimelineReadingBookmarks::Contract.timeline_id(source, context)
  end

  private

  def name_is_stripped_text
    return if name.blank?
    return if name == name.strip && !name.match?(/[[:cntrl:]]/)

    errors.add(:name, 'invalid_name')
  end

  def anchor_status_is_decimal
    return if TimelineSeek::StatusId.parse(anchor_status_id)&.positive?

    errors.add(:anchor_status_id, 'invalid_anchor')
  end

  def context_is_bounded_hash
    unless context.is_a?(Hash)
      errors.add(:context, 'invalid_context')
      return
    end

    errors.add(:context, 'invalid_context') if context.to_json.bytesize > CONTEXT_MAX_BYTES
  end

  def within_user_limit
    return if user_id.nil?
    return if self.class.where(user_id: user_id).count < PER_USER_LIMIT

    errors.add(:base, 'limit')
  end
end
