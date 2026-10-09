# frozen_string_literal: true

# == Schema Information
#
# Table name: user_posting_context_assignments
#
#  id                      :bigint(8)        not null, primary key
#  user_id                 :bigint(8)        not null
#  surface_kind            :string(16)       not null
#  surface_key             :string(100)      not null
#  user_posting_context_id :bigint(8)
#  lock_version            :integer          default(0), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#
class UserPostingContextAssignment < ApplicationRecord
  # No row is unset and may use the one-style guess. A null style is an
  # explicit none. A disabled or mismatched style stays unavailable and is
  # not replaced. Deleting the style nullifies this row into none.
  # Group and list keys are record ids and are not rewritten. Hashtag keys
  # use UserPostingContext::HashtagName. Ownership stays on the user.
  SURFACE_KINDS = %w(group hashtag list).freeze
  STATUSES = %w(unset none style unavailable).freeze

  class InvalidAssignment < StandardError
    attr_reader :assignment

    def initialize(assignment)
      @assignment = assignment
      super(assignment.errors.full_messages.to_sentence.presence || I18n.t('user_posting_context_assignments.errors.invalid'))
    end
  end

  belongs_to :user, inverse_of: :user_posting_context_assignments
  belongs_to :user_posting_context, optional: true, inverse_of: :user_posting_context_assignments

  attr_readonly :user_id, :surface_kind, :surface_key

  validates :surface_kind, inclusion: { in: SURFACE_KINDS }
  validates :surface_key, presence: true, length: { maximum: 100 }
  validates :surface_key, uniqueness: { scope: [:user_id, :surface_kind] }
  validate :surface_contract
  validate :style_contract

  def self.assign!(user:, surface_kind:, surface_key:, style:)
    kind, key = canonicalize!(user, surface_kind, surface_key)
    ensure_style!(user, kind, key, style)

    attempts = 0

    begin
      attempts += 1
      transaction(requires_new: true) do
        existing = user.user_posting_context_assignments.find_by(surface_kind: kind, surface_key: key)

        if existing
          persist_locked!(existing, style)
        else
          user.user_posting_context_assignments.create!(
            surface_kind: kind,
            surface_key: key,
            user_posting_context: style
          )
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < 3
      raise
    end
  end

  def self.canonicalize!(user, surface_kind, surface_key)
    kind = surface_kind.to_s
    key = surface_key.to_s
    pair = normalized_surface(user, kind, key)
    return pair if pair

    record = new(surface_kind: kind, surface_key: key)
    record.errors.add(:base, I18n.t('user_posting_context_assignments.errors.surface'))
    raise InvalidAssignment, record
  end

  def self.unset_payload(kind, key)
    {
      surface: { kind: kind, key: key },
      status: 'unset',
      style_id: nil,
      revision: nil,
    }
  end

  def self.normalized_surface(user, kind, key)
    case kind
    when 'group'
      group_surface(key)
    when 'hashtag'
      hashtag_surface(key)
    when 'list'
      list_surface(user, key)
    end
  end

  def self.style_fits_surface?(style, kind, key)
    return false if style.nil?
    return true if style.target_kind == 'none'

    case kind
    when 'group'
      style.target_kind == 'group' && style.target_account_id.to_s == key
    when 'hashtag'
      return false unless style.target_kind == 'hashtag'

      pair = UserPostingContext::HashtagName.canonicalize(style.target_hashtag)
      pair.present? && pair.last == key
    else
      false
    end
  end

  # One grouped read for every style a user references. Callers that need
  # active and unavailable split still use availability_status on a
  # preloaded relation, not one count per card.
  def self.reference_counts_by_style(user)
    return {} if user.nil?

    user.user_posting_context_assignments.where.not(user_posting_context_id: nil).group(:user_posting_context_id).count
  end

  # Settings clears a place by its row id. The surface does not have to
  # still exist. A stale lock_version does not delete a newer choice.
  def release!(expected_lock_version)
    with_lock do
      assert_expected_lock!(expected_lock_version)
      destroy!
    end
  end

  # Keeps the row and stores an explicit none. Creating a new assignment
  # still goes through assign! and its surface checks.
  def decline!(expected_lock_version)
    with_lock do
      assert_expected_lock!(expected_lock_version)
      clear_style! if user_posting_context_id.present?
    end
    self
  end

  def api_payload
    status = availability_status

    {
      surface: { kind: surface_kind, key: surface_key },
      status: status,
      style_id: %w(style unavailable).include?(status) ? user_posting_context_id.to_s : nil,
      revision: lock_version,
    }
  end

  def availability_status
    return 'none' if user_posting_context_id.nil?

    style = user_posting_context

    if style.nil? || style.user_id != user_id || !style.enabled? || !self.class.style_fits_surface?(style, surface_kind, surface_key)
      return 'unavailable'
    end

    'style'
  end

  class << self
    private

    def persist_locked!(existing, style)
      existing.with_lock do
        existing.update!(user_posting_context: style) if existing.user_posting_context_id != style&.id
        existing
      end
    end

    def ensure_style!(user, kind, key, style)
      return if style.nil?
      return if style.user_id == user.id && style.enabled? && style_fits_surface?(style, kind, key)

      record = new(surface_kind: kind, surface_key: key)
      record.errors.add(:base, I18n.t('user_posting_context_assignments.errors.style'))
      raise InvalidAssignment, record
    end

    def group_surface(key)
      return unless key.match?(/\A[1-9][0-9]*\z/)

      account = Account.find_by(id: key)
      return unless account&.group? && account.id.to_s == key

      ['group', account.id.to_s]
    end

    def hashtag_surface(key)
      pair = UserPostingContext::HashtagName.canonicalize(key)
      return unless pair

      ['hashtag', pair.last]
    end

    def list_surface(user, key)
      return unless key.match?(/\A[1-9][0-9]*\z/)
      return if user.nil? || user.account_id.nil?

      list = List.find_by(id: key)
      return unless list && list.account_id == user.account_id && list.id.to_s == key

      ['list', list.id.to_s]
    end
  end

  private

  def clear_style!
    self.user_posting_context = nil
    if valid?
      save!
    else
      nullify_style_without_surface_check!
    end
  end

  def assert_expected_lock!(expected_lock_version)
    given = Integer(expected_lock_version)
    return if lock_version == given

    raise ActiveRecord::StaleObjectError.new(self, 'update')
  rescue ArgumentError, TypeError
    raise ActiveRecord::StaleObjectError.new(self, 'update')
  end

  def nullify_style_without_surface_check!
    update_columns(
      user_posting_context_id: nil,
      lock_version: lock_version + 1,
      updated_at: Time.now.utc
    )
    reload
  end

  def surface_contract
    return if user.nil? || surface_kind.blank? || surface_key.blank?

    pair = self.class.normalized_surface(user, surface_kind, surface_key)
    return if pair == [surface_kind, surface_key]

    errors.add(:base, I18n.t('user_posting_context_assignments.errors.surface'))
  end

  def style_contract
    return if user_posting_context_id.nil?

    style = user_posting_context
    return if style && style.user_id == user_id && style.enabled? && self.class.style_fits_surface?(style, surface_kind, surface_key)

    errors.add(:base, I18n.t('user_posting_context_assignments.errors.style'))
  end
end
