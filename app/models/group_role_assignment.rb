# frozen_string_literal: true

# Local owner or moderator for a managed group. This is not GroupAffiliation
# and it does not follow or unfollow anyone. Active rows are unique per
# member, and each group has at most one active owner. The group Account
# itself cannot hold a role. Remote members are rejected until a later phase
# enables them; the columns do not hard-code a local-only foreign key.
class GroupRoleAssignment < ApplicationRecord
  enum role: { owner: 0, moderator: 1 }

  belongs_to :group_account, class_name: 'Account', inverse_of: :group_role_assignments
  belongs_to :member_account, class_name: 'Account', inverse_of: :held_group_roles
  belongs_to :granted_by_account, class_name: 'Account', optional: true
  belongs_to :managed_group, foreign_key: :group_account_id, primary_key: :account_id, optional: true, inverse_of: :role_assignments

  scope :active, -> { where(revoked_at: nil) }

  validates :role, presence: true
  validates :granted_at, presence: true
  validate :group_is_managed
  validate :member_is_eligible, on: :create
  validate :single_active_owner
  validate :single_active_member
  validate :identity_is_immutable, on: :update
  validate :revocation_moves_forward, on: :update
  validate :approved_group_keeps_its_owner, on: :update

  before_validation :assign_granted_at, on: :create

  def revoke!(revoked_at: Time.current)
    update!(revoked_at: revoked_at)
  end

  # Revoke the current owner and insert the successor in one transaction.
  # Lock the managed group first, then the active owner row. The partial
  # unique index allows the new owner only after the previous row is
  # revoked, and a failed insert rolls that revocation back. This does not
  # change GroupCreationRequest#initial_owner_account_id. Offer and acceptance
  # stay in the P3 service.
  def self.transfer_owner!(group_account:, member_account:, granted_by_account: nil, transferred_at: Time.current)
    transaction do
      managed = ManagedGroup.lock.find_by!(account_id: group_account.id)
      current = active.owner.lock.find_by!(group_account_id: group_account.id)
      current.send(:transfer_owner_to!, managed, member_account, granted_by_account, transferred_at)
    end
  end

  private

  def transfer_owner_to!(managed, member_account, granted_by_account, transferred_at)
    unless managed.approved_request? && managed.creation_request&.approved?
      errors.add(:group_account, :invalid)
      raise ActiveRecord::RecordInvalid, self
    end
    if member_account&.id == member_account_id
      errors.add(:member_account, :invalid)
      raise ActiveRecord::RecordInvalid, self
    end

    @replacing_owner = true
    update!(revoked_at: transferred_at)
    self.class.create!(
      group_account_id: group_account_id,
      member_account: member_account,
      role: :owner,
      granted_by_account: granted_by_account,
      granted_at: transferred_at
    )
  end

  def assign_granted_at
    self.granted_at ||= Time.current
  end

  def group_is_managed
    return if group_account&.local? && group_account&.group? && ManagedGroup.exists?(account_id: group_account_id)

    errors.add(:group_account, :invalid)
  end

  def member_is_eligible
    errors.add(:member_account, :invalid) if member_account_id.present? && member_account_id == group_account_id
    errors.add(:member_account, :invalid) unless GroupManagement.local_functional_person?(member_account)
    return if granted_by_account.nil?

    errors.add(:granted_by_account, :invalid) unless granted_by_account.local?
  end

  def single_active_owner
    return unless owner? && revoked_at.nil?

    scope = self.class.active.owner.where(group_account_id: group_account_id)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:role, :taken) if scope.exists?
  end

  def single_active_member
    return if revoked_at.present? || member_account_id.blank? || group_account_id.blank?

    scope = self.class.active.where(group_account_id: group_account_id, member_account_id: member_account_id)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:member_account_id, :taken) if scope.exists?
  end

  def identity_is_immutable
    %w(group_account_id member_account_id role granted_at granted_by_account_id).each do |attribute|
      errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
    end
  end

  def revocation_moves_forward
    return unless will_save_change_to_revoked_at?

    errors.add(:revoked_at, :invalid) if revoked_at_in_database.present? || revoked_at.nil?
    errors.add(:revoked_at, :invalid) if granted_at.present? && revoked_at.present? && revoked_at < granted_at
  end

  def approved_group_keeps_its_owner
    return if @replacing_owner
    return unless will_save_change_to_revoked_at? && owner? && revoked_at.present?
    return unless approved_group_requires_owner?

    others = self.class.active.owner.where(group_account_id: group_account_id).where.not(id: id)
    errors.add(:revoked_at, :owner_required) unless others.exists?
  end

  def approved_group_requires_owner?
    managed = ManagedGroup.lock.find_by(account_id: group_account_id)
    managed&.approved_request? && managed.creation_request&.approved?
  end
end
