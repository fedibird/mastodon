# frozen_string_literal: true

# == Schema Information
#
# Table name: posting_identity_request_allowances
#
#  id                :bigint(8)        not null, primary key
#  grantor_user_id   :bigint(8)        not null
#  requester_user_id :bigint(8)        not null
#  allowed_scopes    :string           default([]), not null, is an Array
#  allowed_at        :datetime         not null
#  expires_at        :datetime         not null
#  revoked_at        :datetime
#  generation        :integer          default(1), not null
#  lock_version      :integer          default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class PostingIdentityRequestAllowance < ApplicationRecord
  TTL = 7.days

  belongs_to :grantor_user, class_name: 'User'
  belongs_to :requester_user, class_name: 'User'

  attr_readonly :grantor_user_id, :requester_user_id

  validates :allowed_at, :expires_at, :generation, presence: true
  validate :parties_stay_distinct
  validate :revocation_requires_new_generation, on: :update
  validate :scope_list_is_closed

  def active?
    revoked_at.nil? && expires_at.future?
  end

  def covers?(scopes)
    requested = Array(scopes).map(&:to_s)
    (requested - Array(allowed_scopes).map(&:to_s)).empty?
  end

  def matches_request?(request)
    return false if request.nil?
    return false unless grantor_user_id == request.target_user_id
    return false unless requester_user_id == request.requester_user_id
    return false unless generation == request.allowance_generation
    return false unless active?
    return false unless covers?(request.scopes)

    true
  end

  private

  def parties_stay_distinct
    errors.add(:requester_user_id, :invalid) if grantor_user_id.present? && grantor_user_id == requester_user_id
  end

  def revocation_requires_new_generation
    return unless revoked_at_changed? && revoked_at.nil? && revoked_at_was.present?
    return if generation_changed? && generation.to_i > generation_was.to_i

    errors.add(:revoked_at, :invalid)
  end

  def scope_list_is_closed
    errors.add(:allowed_scopes, :invalid) unless PostingIdentity::Scopes.valid?(allowed_scopes)
  end
end
