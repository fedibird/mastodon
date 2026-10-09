# frozen_string_literal: true

# == Schema Information
#
# Table name: posting_identity_link_requests
#
#  id                   :bigint(8)        not null, primary key
#  requester_user_id    :bigint(8)        not null
#  target_user_id       :bigint(8)        not null
#  token_digest         :string(64)       not null
#  scopes               :string           default([]), not null, is an Array
#  expires_at           :datetime         not null
#  consumed_at          :datetime
#  canceled_at          :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  request_allowance_id :bigint(8)
#  allowance_generation :integer
#
class PostingIdentityLinkRequest < ApplicationRecord
  REQUEST_TTL = 30.minutes

  belongs_to :requester_user, class_name: 'User'
  belongs_to :target_user, class_name: 'User'
  belongs_to :request_allowance, class_name: 'PostingIdentityRequestAllowance', optional: true

  attr_readonly :requester_user_id, :target_user_id, :token_digest, :scopes, :request_allowance_id, :allowance_generation

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validate :parties_stay_distinct

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.generate_token
    SecureRandom.urlsafe_base64(32)
  end

  def open?
    consumed_at.nil? && canceled_at.nil? && expires_at.future?
  end

  def expired?
    expires_at <= Time.current
  end

  private

  def parties_stay_distinct
    errors.add(:target_user_id, :invalid) if requester_user_id.present? && requester_user_id == target_user_id
  end
end
