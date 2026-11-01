# frozen_string_literal: true

# Local administration record for one group Account. Creating this row is
# explicit. Existing groups are not enrolled, and legacy_unassigned is stored
# only so a later migration can use it. P0 refuses to write that origin.
class ManagedGroup < ApplicationRecord
  enum origin: { approved_request: 0, legacy_unassigned: 1 }

  belongs_to :account, inverse_of: :managed_group
  belongs_to :creation_request, class_name: 'GroupCreationRequest', optional: true, inverse_of: :managed_group
  has_many :role_assignments, class_name: 'GroupRoleAssignment', foreign_key: :group_account_id, primary_key: :account_id, inverse_of: :managed_group
  has_one :registration_invite_policy, class_name: 'GroupRegistrationInvitePolicy', inverse_of: :managed_group, dependent: :restrict_with_exception

  validates :origin, presence: true
  validates :account_id, uniqueness: true
  validates :creation_request_id, uniqueness: true, allow_nil: true
  validate :legacy_origin_is_deferred
  validate :account_is_local_group
  validate :request_matches_account

  private

  def legacy_origin_is_deferred
    errors.add(:origin, :invalid) if legacy_unassigned?
  end

  def account_is_local_group
    return if account&.local? && account&.group?

    errors.add(:account, :invalid)
  end

  def request_matches_account
    if legacy_unassigned?
      errors.add(:creation_request, :present) if creation_request_id.present?
      return
    end

    errors.add(:creation_request, :blank) if creation_request.nil?
    return if creation_request.nil? || account.nil?
    return unless account.local? && account.group?

    errors.add(:account, :invalid) unless account.username.to_s.downcase == creation_request.username
    return if creation_request.group_account_id.nil? || creation_request.group_account_id == account.id

    errors.add(:account, :invalid)
  end
end
