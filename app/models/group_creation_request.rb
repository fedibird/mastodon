# frozen_string_literal: true

# A person's request to open a local group. Saving a row does not create a
# group Account, reserve the username, or assign an owner. Pending columns
# are the review snapshot. Approval records a decision only after the group
# Account, ManagedGroup, and single owner already exist in the same
# transaction. See docs/group_management_p0.md.
#
# An optional icon is a private original staged outside Paperclip. The bytes
# are not an Account avatar. See docs/group_management_p1.md.
class GroupCreationRequest < ApplicationRecord
  USERNAME_PATTERN = /\A[a-z0-9_]{1,30}\z/
  NOTE_LIMIT = 500
  SUBMISSION_TOKEN_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # Form-only. Paperclip would publish this through the public storage
  # defaults, so the column is not an attachment.
  attr_accessor :icon

  enum state: { pending: 0, approved: 1, rejected: 2, cancelled: 3 }

  belongs_to :requester_account, class_name: 'Account', inverse_of: :group_creation_requests
  belongs_to :reviewer_account, class_name: 'Account', optional: true
  belongs_to :group_account, class_name: 'Account', optional: true
  belongs_to :previous_request, class_name: 'GroupCreationRequest', optional: true
  belongs_to :initial_owner_account, class_name: 'Account', optional: true
  has_one :managed_group, foreign_key: :creation_request_id, inverse_of: :creation_request, dependent: :restrict_with_exception
  has_one :successor_request, class_name: 'GroupCreationRequest', foreign_key: :previous_request_id, inverse_of: :previous_request, dependent: :restrict_with_exception

  validates :username, presence: true, format: { with: USERNAME_PATTERN }, length: { maximum: 30 }
  validates_with UnreservedUsernameValidator, on: :create
  validates_with LocalDisplayNameValidator
  validates :note, note_length: { maximum: NOTE_LIMIT }
  validates :requested_at, presence: true
  validates :state, presence: true
  validates :previous_request_id, uniqueness: true, allow_nil: true
  validates :group_account_id, uniqueness: true, allow_nil: true
  validates :submission_token, uniqueness: true, allow_nil: true, format: { with: SUBMISSION_TOKEN_PATTERN }
  validates :icon_storage_key, uniqueness: true, allow_nil: true

  validate :starts_pending, on: :create
  validate :icon_shape, on: :create
  validate :requester_is_eligible, on: :create
  validate :username_is_free, on: :create
  validate :previous_request_is_reapplication, on: :create
  validate :snapshot_is_immutable, on: :update
  validate :icon_columns_are_immutable, on: :update
  validate :initial_owner_is_fixed, on: :update
  validate :state_transition_is_legal, on: :update
  validate :decision_shape

  before_validation :normalize_snapshot, on: :create
  before_validation :normalize_decision_note
  before_validation :assign_requested_at, on: :create

  after_commit :purge_terminal_icon, on: :update
  after_commit :purge_destroyed_icon, on: :destroy

  def self.local_username_taken?(username)
    normalized = username.to_s.downcase
    return false if normalized.blank?

    Account.where(Account.arel_table[:domain].eq(nil))
           .where(Account.arel_table[:username].lower.eq(normalized))
           .exists?
  end

  def self.reserved_username?(username)
    normalized = username.to_s.downcase
    return false if normalized.blank?

    names = Setting.reserved_usernames
    return false if names.blank?

    names.any? { |name| name.to_s.downcase == normalized }
  end

  # P2 calls this before inserting the group Account. A pending row is not a
  # reservation, so another pending request or a later Account can still
  # take the same name.
  def username_available_for_approval?
    return false unless username.to_s.match?(USERNAME_PATTERN)
    return false if self.class.reserved_username?(username)

    !self.class.local_username_taken?(username)
  end

  def record_approval!(reviewer_account:, group_account:, reviewed_at: Time.current, decision_note: nil)
    transaction do
      lock!
      unless pending?
        errors.add(:state, :invalid)
        raise ActiveRecord::RecordInvalid, self
      end

      owner = GroupRoleAssignment.active.owner.find_by(group_account_id: group_account&.id)
      update!(
        state: :approved,
        reviewer_account: reviewer_account,
        group_account: group_account,
        reviewed_at: reviewed_at,
        decision_note: decision_note,
        initial_owner_account: owner&.member_account
      )
    end
  end

  def record_rejection!(reviewer_account:, decision_note:, reviewed_at: Time.current)
    update!(
      state: :rejected,
      reviewer_account: reviewer_account,
      reviewed_at: reviewed_at,
      decision_note: decision_note
    )
  end

  def icon_previewable?
    icon_storage_key.present? && icon_purged_at.nil?
  end

  def record_cancellation!(cancelled_at: Time.current, decision_note: nil)
    update!(
      state: :cancelled,
      cancelled_at: cancelled_at,
      decision_note: decision_note
    )
  end

  private

  def normalize_snapshot
    self.username = username.to_s.squish.downcase
    self.display_name = display_name.to_s.strip
    self.note = note.to_s.strip
  end

  def normalize_decision_note
    self.decision_note = decision_note.to_s.strip.presence
  end

  def assign_requested_at
    self.requested_at ||= Time.current
    self.state ||= :pending
  end

  def starts_pending
    errors.add(:state, :invalid) unless pending?
  end

  def requester_is_eligible
    errors.add(:requester_account, :invalid) unless GroupManagement.local_functional_person?(requester_account)
  end

  def username_is_free
    return if username.blank?
    return unless self.class.local_username_taken?(username)

    errors.add(:username, :taken)
  end

  def previous_request_is_reapplication
    return if previous_request_id.blank?

    prior = previous_request
    return errors.add(:previous_request_id, :invalid) if prior.nil?
    return errors.add(:previous_request_id, :invalid) if prior.requester_account_id != requester_account_id
    return errors.add(:previous_request_id, :invalid) unless prior.rejected? || prior.cancelled?

    errors.add(:previous_request_id, :invalid) if prior.id == id
  end

  def icon_shape
    if icon_storage_key.blank?
      errors.add(:icon_content_type, :invalid) if icon_content_type.present?
      errors.add(:icon_byte_size, :invalid) if icon_byte_size.present?
      errors.add(:icon_purged_at, :invalid) if icon_purged_at.present?
      return
    end

    errors.add(:icon_storage_key, :invalid) unless icon_storage_key.match?(GroupCreationIcons::KEY_FORMAT)
    errors.add(:icon_content_type, :invalid) unless AccountAvatar::IMAGE_MIME_TYPES.include?(icon_content_type)
    errors.add(:icon_byte_size, :invalid) unless icon_byte_size.is_a?(Integer) && icon_byte_size.positive? && icon_byte_size < AccountAvatar::LIMIT
  end

  def icon_columns_are_immutable
    %w(icon_storage_key icon_content_type icon_byte_size submission_token).each do |attribute|
      errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
    end
    return unless will_save_change_to_icon_purged_at?

    errors.add(:icon_purged_at, :immutable) if icon_purged_at_in_database.present?
    errors.add(:icon_purged_at, :invalid) if icon_storage_key.blank?
  end

  def purge_terminal_icon
    return unless saved_change_to_state?
    return unless rejected? || cancelled?

    GroupCreationIcons::Purge.call(self)
  rescue StandardError => e
    Rails.logger.error("Group creation icon purge failed request_id=#{id} error=#{e.class}")
  end

  def purge_destroyed_icon
    return if icon_storage_key.blank?

    GroupCreationIcons::Storage.resolve.delete(icon_storage_key)
  rescue StandardError => e
    Rails.logger.error("Group creation icon delete failed request_id=#{id} error=#{e.class}")
  end

  def snapshot_is_immutable
    %w(requester_account_id username display_name note requested_at previous_request_id).each do |attribute|
      errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
    end
  end

  def initial_owner_is_fixed
    return unless will_save_change_to_initial_owner_account_id?
    return if initial_owner_account_id_in_database.nil?

    errors.add(:initial_owner_account_id, :immutable)
  end

  def state_transition_is_legal
    return unless will_save_change_to_state?

    raw = state_in_database
    from = self.class.states.key(raw) || raw
    allowed = { 'pending' => %w(approved rejected cancelled) }
    errors.add(:state, :invalid) unless allowed.fetch(from.to_s, []).include?(state.to_s)
  end

  def decision_shape
    if pending?
      errors.add(:reviewer_account, :invalid) if reviewer_account_id.present?
      errors.add(:reviewed_at, :invalid) if reviewed_at.present?
      errors.add(:group_account, :invalid) if group_account_id.present?
      errors.add(:cancelled_at, :invalid) if cancelled_at.present?
      errors.add(:initial_owner_account, :invalid) if initial_owner_account_id.present?
      errors.add(:decision_note, :invalid) if decision_note.present?
      return
    end

    if approved?
      errors.add(:reviewer_account, :invalid) unless GroupManagement.server_administrator?(reviewer_account)
      errors.add(:reviewed_at, :blank) if reviewed_at.blank?
      errors.add(:cancelled_at, :invalid) if cancelled_at.present?
      approval_matches_group
      return
    end

    if rejected?
      errors.add(:reviewer_account, :invalid) unless GroupManagement.server_administrator?(reviewer_account)
      errors.add(:reviewed_at, :blank) if reviewed_at.blank?
      errors.add(:decision_note, :blank) if decision_note.blank?
      errors.add(:group_account, :invalid) if group_account_id.present?
      errors.add(:cancelled_at, :invalid) if cancelled_at.present?
      errors.add(:initial_owner_account, :invalid) if initial_owner_account_id.present?
      return
    end

    errors.add(:reviewer_account, :invalid) if reviewer_account_id.present?
    errors.add(:reviewed_at, :invalid) if reviewed_at.present?
    errors.add(:group_account, :invalid) if group_account_id.present?
    errors.add(:cancelled_at, :blank) if cancelled_at.blank?
    errors.add(:initial_owner_account, :invalid) if initial_owner_account_id.present?
  end

  def approval_matches_group
    errors.add(:group_account, :blank) if group_account.nil?
    return if group_account.nil?

    errors.add(:group_account, :invalid) unless group_account.local? && group_account.group?
    errors.add(:group_account, :invalid) unless group_account.username.to_s.downcase == username

    managed = ManagedGroup.find_by(account_id: group_account.id)
    errors.add(:group_account, :invalid) unless managed&.approved_request? && managed.creation_request_id == id

    owner = GroupRoleAssignment.active.owner.find_by(group_account_id: group_account.id)
    errors.add(:initial_owner_account, :invalid) unless owner&.member_account_id == requester_account_id
    errors.add(:initial_owner_account, :invalid) unless initial_owner_account_id == requester_account_id
    errors.add(:initial_owner_account, :invalid) unless GroupManagement.local_functional_person?(initial_owner_account)
  end
end
