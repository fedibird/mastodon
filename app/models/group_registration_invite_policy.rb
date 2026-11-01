# frozen_string_literal: true

# == Schema Information
#
# Table name: group_registration_invite_policies
#
#  id                        :bigint(8)        not null, primary key
#  managed_group_id          :bigint(8)        not null
#  group_account_id          :bigint(8)        not null
#  issuance_enabled          :boolean          not null
#  shared_registration_quota :integer          not null
#  shared_quota_unlimited    :boolean          default(FALSE), not null
#  per_link_max_uses         :integer
#  per_link_unlimited_uses   :boolean          default(FALSE), not null
#  per_link_lifetime_seconds :integer
#  per_link_indefinite       :boolean          default(FALSE), not null
#  copied_at                 :datetime         not null
#  lock_version              :integer          default(0), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#
# Per-group snapshot of the site's registration-invite defaults.
# Copied once inside the approval transaction. Later changes to Setting do
# not rewrite this row, and creating an Account does not create one.
# P5 locks this row to consume shared_registration_quota. This model does
# not issue URLs or decrement the quota.
#
# Unlimited shared quota stores 0 in the number column and ignores it.
# A per-link use cap is either a positive integer or per_link_unlimited_uses,
# never both. A per-link lifetime is either a positive number of seconds or
# per_link_indefinite, never both. Issuance starts disabled, so the row
# cannot be used until a later phase turns it on.
class GroupRegistrationInvitePolicy < ApplicationRecord
  belongs_to :managed_group, inverse_of: :registration_invite_policy
  belongs_to :group_account, class_name: 'Account', inverse_of: :group_registration_invite_policy

  validates :copied_at, presence: true
  validates :managed_group_id, uniqueness: true
  validates :group_account_id, uniqueness: true
  validates :shared_registration_quota, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :limits_are_consistent
  validate :group_matches_managed_row
  validate :identity_is_fixed, on: :update

  def self.copy_site_defaults!(managed_group:, copied_at: Time.current)
    create!(
      GroupRegistrationInvites::SiteDefaults.snapshot.merge(
        managed_group: managed_group,
        group_account_id: managed_group.account_id,
        copied_at: copied_at
      )
    )
  end

  private

  def limits_are_consistent
    errors.add(:shared_registration_quota, :invalid) if shared_quota_unlimited? && shared_registration_quota.to_i != 0
    errors.add(:per_link_max_uses, :invalid) if per_link_unlimited_uses? && per_link_max_uses.present?
    errors.add(:per_link_max_uses, :greater_than_or_equal_to, count: 1) if !per_link_unlimited_uses? && per_link_max_uses.to_i < 1
    errors.add(:per_link_lifetime_seconds, :invalid) if per_link_indefinite? && per_link_lifetime_seconds.present?
    errors.add(:per_link_lifetime_seconds, :greater_than_or_equal_to, count: 1) if !per_link_indefinite? && per_link_lifetime_seconds.to_i < 1
  end

  def group_matches_managed_row
    return if managed_group.nil? || group_account.nil?

    errors.add(:managed_group, :invalid) unless managed_group.approved_request?
    errors.add(:group_account, :invalid) unless managed_group.account_id == group_account_id
    errors.add(:group_account, :invalid) unless group_account.local? && group_account.group?
  end

  def identity_is_fixed
    %w(managed_group_id group_account_id copied_at).each do |attribute|
      errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
    end
  end
end
