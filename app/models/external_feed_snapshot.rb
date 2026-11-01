# frozen_string_literal: true

# == Schema Information
#
# Table name: external_feed_snapshots
#
#  id                  :bigint(8)        not null, primary key
#  external_source_id  :bigint(8)        not null
#  generation          :integer          not null
#  state               :string           default("pending"), not null
#  etag                :text
#  last_modified       :text
#  body                :text
#  byte_size           :integer          not null
#  item_count          :integer          default(0), not null
#  next_index          :integer          default(0), not null
#  history_positions   :jsonb            default([]), not null
#  history_applied_at  :datetime
#  lease_token         :string
#  lease_expires_at    :datetime
#  batch_count         :integer          default(0), not null
#  attempt_count       :integer          default(0), not null
#  last_error_code     :string
#  completed_at        :datetime
#  body_purged_at      :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class ExternalFeedSnapshot < ApplicationRecord
  STATES = %w(pending draining complete failed).freeze
  OPEN_STATES = %w(pending draining).freeze

  belongs_to :external_source

  validates :state, inclusion: { in: STATES }
  validates :generation, numericality: { only_integer: true, greater_than: 0 }

  scope :open, -> { where(state: OPEN_STATES) }

  def self.purge_expired!(limit: 50)
    cutoff = ExternalBridge::RSS::Limits::SNAPSHOT_BODY_RETENTION.ago
    ids = where.not(body: nil).where(state: %w(complete failed)).where('COALESCE(completed_at, updated_at) < ?', cutoff).limit(limit).pluck(:id)
    return 0 if ids.empty?

    where(id: ids).update_all(body: nil, body_purged_at: Time.current, updated_at: Time.current)
  end

  def history_position_list
    Array(self[:history_positions]).map(&:to_i)
  end

  def open?
    OPEN_STATES.include?(state)
  end

  def claim_lease!(now: Time.current)
    token = SecureRandom.hex(16)
    expiry = now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE
    updated = self.class.where(id: id, state: OPEN_STATES)
                  .where('attempt_count < ?', ExternalBridge::RSS::Limits::SNAPSHOT_ATTEMPT_CEILING)
                  .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
                  .update_all(lease_token: token, lease_expires_at: expiry, state: 'draining', updated_at: now)
    return nil unless updated == 1

    reload
    token
  end

  def release_lease!(token)
    self.class.where(id: id, lease_token: token, state: OPEN_STATES).update_all(lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
  end

  def complete!(token)
    now = Time.current
    self.class.where(id: id, lease_token: token).update_all(
      state: 'complete',
      next_index: item_count,
      lease_token: nil,
      lease_expires_at: nil,
      completed_at: now,
      updated_at: now
    )
  end

  def fail!(code)
    now = Time.current
    self.class.where(id: id, state: OPEN_STATES).update_all(
      state: 'failed',
      last_error_code: code.to_s,
      lease_token: nil,
      lease_expires_at: nil,
      updated_at: now
    )
  end

  # Returns true when this attempt moved the row to failed.
  def note_attempt!(code)
    now = Time.current
    ceiling = ExternalBridge::RSS::Limits::SNAPSHOT_ATTEMPT_CEILING
    self.class.where(id: id).update_all(
      [
        "attempt_count = attempt_count + 1, last_error_code = ?, lease_token = NULL, lease_expires_at = NULL, updated_at = ?, state = CASE WHEN attempt_count + 1 >= ? AND state IN ('pending', 'draining') THEN 'failed' ELSE state END",
        code.to_s,
        now,
        ceiling,
      ]
    )
    reload
    state == 'failed'
  end
end
