# frozen_string_literal: true

# == Schema Information
#
# Table name: reboost_cooldowns
#
#  id         :bigint(8)        not null, primary key
#  account_id :bigint(8)        not null
#  status_id  :bigint(8)        not null
#  boosted_at :datetime         not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
module Reboost
  COOLDOWN_SECONDS = 300 unless const_defined?(:COOLDOWN_SECONDS, false)
  FEDERATION_GAP = 10.seconds unless const_defined?(:FEDERATION_GAP, false)
end

class ReboostCooldown < ApplicationRecord
  belongs_to :account
  belongs_to :status

  def self.remaining_seconds(account_id, status_id, now: Time.current)
    boosted_at = where(account_id: account_id, status_id: status_id).pick(:boosted_at)
    return 0 if boosted_at.nil?

    remaining = (boosted_at + Reboost::COOLDOWN_SECONDS) - now
    remaining.positive? ? remaining.ceil : 0
  end

  def self.retry_after_map(account_id, status_ids, now: Time.current)
    return {} if account_id.blank? || status_ids.blank?

    where(account_id: account_id, status_id: status_ids).each_with_object({}) do |row, map|
      remaining = ((row.boosted_at + Reboost::COOLDOWN_SECONDS) - now).ceil
      map[row.status_id] = remaining if remaining.positive?
    end
  end

  # The caller holds the account+status lock and has already created the boost.
  def self.stamp!(account_id, status_id, now: Time.current)
    row = find_or_initialize_by(account_id: account_id, status_id: status_id)
    row.boosted_at = now
    row.save!
  rescue ActiveRecord::RecordNotUnique
    find_by!(account_id: account_id, status_id: status_id).update!(boosted_at: now)
  end
end
