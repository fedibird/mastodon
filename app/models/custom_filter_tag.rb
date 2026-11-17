# frozen_string_literal: true

# == Schema Information
#
# Table name: custom_filter_tags
#
#  id               :bigint           not null, primary key
#  custom_filter_id :bigint           not null
#  account_id       :bigint           not null
#  name             :text             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# One exact hashtag on a viewer's filter. `name` is the case-folded tag
# identity used by Tag.matching_name, without a leading # or ＃.
class CustomFilterTag < ApplicationRecord
  include CustomFilterCache

  NAME_LIMIT = 200

  belongs_to :custom_filter, inverse_of: :filter_tags
  belongs_to :account

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :account_id, uniqueness: { scope: :name }
  validate :account_matches_filter

  before_validation :assign_normalized_name

  def self.normalize_name(raw)
    stripped = raw.to_s.strip.gsub(/\A[#＃]+/, '')
    return if stripped.blank? || stripped.length > NAME_LIMIT
    return unless stripped.match?(Tag::HASHTAG_NAME_RE)

    stripped.mb_chars.downcase.to_s
  end

  def self.display_name(raw)
    raw.to_s.strip.gsub(/\A[#＃]+/, '')
  end

  private

  def assign_normalized_name
    self.name = self.class.normalize_name(name)
  end

  def account_matches_filter
    return if custom_filter.nil? || account_id.nil?
    return if custom_filter.account_id == account_id

    errors.add(:account_id, :invalid)
  end
end
