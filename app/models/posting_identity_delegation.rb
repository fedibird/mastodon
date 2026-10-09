# frozen_string_literal: true

# == Schema Information
#
# Table name: posting_identity_delegations
#
#  id                 :bigint(8)        not null, primary key
#  grantor_user_id    :bigint(8)        not null
#  grantee_user_id    :bigint(8)        not null
#  posting_account_id :bigint(8)        not null
#  scopes             :string           default([]), not null, is an Array
#  expires_at         :datetime         not null
#  approved_at        :datetime         not null
#  revoked_at         :datetime
#  superseded_at      :datetime
#  last_used_at       :datetime
#  lock_version       :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class PostingIdentityDelegation < ApplicationRecord
  GRANT_TTL = 30.days

  belongs_to :grantor_user, class_name: 'User'
  belongs_to :grantee_user, class_name: 'User'
  belongs_to :posting_account, class_name: 'Account'

  attr_readonly :grantor_user_id, :grantee_user_id, :posting_account_id, :scopes, :approved_at

  validates :expires_at, :approved_at, presence: true
  validate :revocation_sticks, on: :update
  validate :scope_list_is_closed

  scope :occupying_slot, -> { where(revoked_at: nil, superseded_at: nil) }
  scope :for_grantee, ->(user) { where(grantee_user_id: user.id) }
  scope :for_grantor, ->(user) { where(grantor_user_id: user.id) }

  def active_record?
    revoked_at.nil? && superseded_at.nil? && expires_at.future?
  end

  def revoke!(at: Time.current)
    raise ActiveRecord::RecordInvalid, self if revoked_at.present?

    update!(revoked_at: at)
  end

  private

  def revocation_sticks
    errors.add(:revoked_at, :invalid) if revoked_at_changed? && revoked_at.nil? && revoked_at_was.present?
    errors.add(:superseded_at, :invalid) if superseded_at_changed? && superseded_at.nil? && superseded_at_was.present?
  end

  def scope_list_is_closed
    errors.add(:scopes, :invalid) unless PostingIdentity::Scopes.valid?(scopes)
  end
end
