# frozen_string_literal: true

# == Schema Information
#
# Table name: external_feed_catch_ups
#
#  id                         :bigint(8)        not null, primary key
#  external_subscription_id   :bigint(8)        not null
#  external_feed_snapshot_id  :bigint(8)
#  position                   :integer          default(0), not null
#  generation                 :integer          default(0), not null
#  state                      :string           default("pending"), not null
#  lease_token                :string
#  lease_expires_at           :datetime
#  busy_retry_at              :datetime
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#
class ExternalFeedCatchUp < ApplicationRecord
  STATES = %w(pending running done stopped).freeze

  belongs_to :external_subscription
  belongs_to :external_feed_snapshot, optional: true

  validates :state, inclusion: { in: STATES }

  def claim!(now: Time.current)
    token = SecureRandom.hex(16)
    expiry = now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE
    updated = self.class.where(id: id)
                  .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
                  .where(state: %w(pending running))
                  .update_all(lease_token: token, lease_expires_at: expiry, state: 'running', busy_retry_at: nil, updated_at: now)
    return nil unless updated == 1

    reload
    token
  end

  def release!(token)
    self.class.where(id: id, lease_token: token).update_all(lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
  end
end
