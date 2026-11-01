# frozen_string_literal: true

# The current owner proposes a successor. Only the proposed local person
# can accept, and accepting is re-authorized under ManagedGroup's row lock.
# A pending offer past expires_at has no authority; it is never accepted.
class GroupOwnerTransferOffer < ApplicationRecord
  enum state: { pending: 0, accepted: 1, cancelled: 2 }

  belongs_to :group_account, class_name: 'Account'
  belongs_to :offered_by_account, class_name: 'Account'
  belongs_to :candidate_account, class_name: 'Account'

  validates :state, presence: true
  validates :expires_at, presence: true
  validate :valid_offer, on: :create
  validate :immutable_identity, on: :update
  validate :valid_transition, on: :update
  validate :response_shape

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  private

  def valid_offer
    managed = ManagedGroup.find_by(account_id: group_account_id)
    unless managed&.approved_request? && managed.creation_request&.approved? && group_account&.local? && group_account&.group?
      errors.add(:group_account, :invalid)
    end

    unless GroupManagement.local_functional_person?(candidate_account)
      errors.add(:candidate_account, :invalid)
    end

    owner = GroupRoleAssignment.active.owner.find_by(group_account_id: group_account_id)
    errors.add(:offered_by_account, :invalid) unless owner&.member_account_id == offered_by_account_id
    errors.add(:candidate_account, :invalid) if candidate_account_id == offered_by_account_id

    errors.add(:expires_at, :invalid) if expires_at.nil? || expires_at <= Time.current
    errors.add(:state, :invalid) unless pending?
  end

  def immutable_identity
    %w(group_account_id offered_by_account_id candidate_account_id expires_at).each do |attr|
      errors.add(attr, :immutable) if will_save_change_to_attribute?(attr)
    end
  end

  def valid_transition
    return unless will_save_change_to_state?

    errors.add(:state, :invalid) unless (self.class.states.key(state_in_database) || state_in_database).to_s == 'pending' && (accepted? || cancelled?)
  end

  def response_shape
    errors.add(:responded_at, :invalid) if pending? && responded_at.present?
    errors.add(:responded_at, :blank) if !pending? && responded_at.nil?
    errors.add(:responded_at, :immutable) if persisted? && responded_at_in_database.present? && will_save_change_to_responded_at?
  end
end
