# frozen_string_literal: true
# == Schema Information
#
# Table name: featured_tags
#
#  id             :bigint(8)        not null, primary key
#  account_id     :bigint(8)
#  tag_id         :bigint(8)
#  statuses_count :bigint(8)        default(0), not null
#  last_status_at :datetime
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  url            :string
#

class FeaturedTag < ApplicationRecord
  belongs_to :account, inverse_of: :featured_tags
  belongs_to :tag, inverse_of: :featured_tags, optional: true # Set after validation

  validate :validate_tag_name, on: :create
  validate :validate_featured_tags_limit, on: :create

  before_create :set_tag
  before_create :reset_data

  # scope :by_name, ->(name) { joins(:tag).where(tag: { name: HashtagNormalizer.new.normalize(name) }) }
  scope :by_name, ->(name) { joins(:tag).where(tag: { name: name }) }

  # delegate :display_name, to: :tag

  attr_writer :name

  LIMIT = 30

  def sign?
    true
  end

  def name
    tag_id.present? ? tag.name : @name
  end

  def increment(timestamp)
    update(statuses_count: statuses_count + 1, last_status_at: timestamp)
  end

  def decrement(deleted_status_id)
    update(
      statuses_count: [0, statuses_count - 1].max,
      last_status_at: matching_statuses.where.not(id: deleted_status_id).pick(:created_at)
    )
  end

  def recount
    reset_data
    save
  end

  private

  def set_tag
    self.tag = Tag.find_or_create_by_names(@name)&.first
  end

  def reset_data
    self.statuses_count = account.statuses.where(visibility: %i(public unlisted)).tagged_with(tag).count
    self.last_status_at = matching_statuses.pick(:created_at)
  end

  # Keep tag membership as a correlated scalar subquery.
  # Joining statuses_tags lets PostgreSQL start from the tag and probe every
  # matching status, which is much slower for featured-tag recounts and decrements.
  def matching_statuses
    account.statuses
           .where(visibility: %i(public unlisted))
           .where(matching_tag_predicate, tag_id: tag_id)
           .reorder(id: :desc)
  end

  def matching_tag_predicate
    <<~SQL.squish
      (
        SELECT TRUE
        FROM statuses_tags
        WHERE statuses_tags.status_id = statuses.id
          AND statuses_tags.tag_id = :tag_id
        LIMIT 1
      ) IS TRUE
    SQL
  end

  def validate_featured_tags_limit
    return unless account.local?

    errors.add(:base, I18n.t('featured_tags.errors.limit')) if account.featured_tags.count >= LIMIT
  end

  def validate_tag_name
    errors.add(:name, :blank) if @name.blank?
    errors.add(:name, :invalid) unless @name.match?(Tag::HASHTAG_NAME_RE)
    errors.add(:name, :taken) if FeaturedTag.by_name(@name).where(account_id: account_id).exists?
  end
end
