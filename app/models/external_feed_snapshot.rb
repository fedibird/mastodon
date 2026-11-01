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
#  isolated_positions  :jsonb            not null
#  retry_positions     :jsonb            not null
#  busy_retry_at       :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class ExternalFeedSnapshot < ApplicationRecord
  STATES = %w(pending draining complete incomplete failed).freeze
  OPEN_STATES = %w(pending draining).freeze

  belongs_to :external_source

  validates :state, inclusion: { in: STATES }
  validates :generation, numericality: { only_integer: true, greater_than: 0 }

  scope :open, -> { where(state: OPEN_STATES) }

  def self.purge_expired!(limit: ExternalBridge::RSS::Limits::SNAPSHOT_PURGE_BATCH)
    ExternalBridge::RSS::FeedSnapshot::Purge.expired!(limit)
  end

  def history_position_list
    Array(self[:history_positions]).map(&:to_i)
  end

  def isolated_entries
    Array(self[:isolated_positions]).filter_map { |entry| isolated_entry(entry) }
  end

  def retry_position_list
    Array(self[:retry_positions]).map(&:to_i)
  end

  def open?
    OPEN_STATES.include?(state)
  end

  # failed while the cursor has not reached the end. Newer generations wait.
  def blocked_remainder?
    state == 'failed' && next_index < item_count
  end

  def claim_lease!(now: Time.current)
    token = SecureRandom.hex(16)
    expiry = now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE
    updated = self.class.where(id: id, state: OPEN_STATES)
                  .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
                  .update_all(lease_token: token, lease_expires_at: expiry, state: 'draining', busy_retry_at: nil, updated_at: now)
    return nil unless updated == 1

    reload
    token
  end

  def release_lease!(token)
    owned_scope(token).update_all(lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
  end

  # True when this token still owned an open row and the cursor was finished.
  def finish!(token)
    now = Time.current
    owned_scope(token).where('next_index >= item_count').update_all(
      [
        "state = CASE WHEN isolated_positions = '[]'::jsonb AND retry_positions = '[]'::jsonb THEN 'complete' ELSE 'incomplete' END, lease_token = NULL, lease_expires_at = NULL, completed_at = ?, updated_at = ?",
        now,
        now,
      ]
    ) == 1
  end

  # True when this token still owned the open row.
  def fail!(code, token)
    now = Time.current
    owned_scope(token).update_all(
      state: 'failed',
      last_error_code: code.to_s,
      lease_token: nil,
      lease_expires_at: nil,
      updated_at: now
    ) == 1
  end

  # Attempt count after a fenced increment, or nil when this token no longer
  # owns the row. Does not clear a lease, so a successor's token stays.
  def note_attempt!(code, token)
    now = Time.current
    updated = owned_scope(token).update_all(
      ['attempt_count = attempt_count + 1, last_error_code = ?, updated_at = ?', code.to_s, now]
    )
    return nil unless updated == 1

    reload
    attempt_count
  end

  # Skip the current cursor position after the attempt ceiling. The rest of
  # this generation stays open. Returns false when the token lost the row.
  def isolate_current!(token, code)
    now = Time.current
    position = next_index
    return false if position >= item_count

    entry = [{ 'position' => position, 'code' => code.to_s }].to_json
    expiry = now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE
    updated = owned_scope(token).where(next_index: position).update_all(
      [
        <<~SQL.squish,
          isolated_positions = isolated_positions || ?::jsonb,
          next_index = next_index + 1,
          attempt_count = 0,
          last_error_code = ?,
          updated_at = ?,
          state = CASE WHEN next_index + 1 >= item_count THEN 'incomplete' ELSE 'draining' END,
          completed_at = CASE WHEN next_index + 1 >= item_count THEN ?::timestamp ELSE completed_at END,
          lease_token = CASE WHEN next_index + 1 >= item_count THEN NULL ELSE lease_token END,
          lease_expires_at = CASE WHEN next_index + 1 >= item_count THEN NULL ELSE ?::timestamp END
        SQL
        entry,
        code.to_s,
        now,
        now,
        expiry,
      ]
    )
    reload
    updated == 1
  end

  # Moves the cursor forward while this token still owns the row.
  def advance_cursor!(token, position, now: Time.current)
    scope = owned_scope(token).where(next_index: position)
    if position + 1 >= item_count
      scope.update_all(
        [
          <<~SQL.squish,
            next_index = next_index + 1,
            updated_at = ?,
            state = CASE WHEN isolated_positions = '[]'::jsonb AND retry_positions = '[]'::jsonb THEN 'complete' ELSE 'incomplete' END,
            completed_at = ?::timestamp,
            lease_token = NULL,
            lease_expires_at = NULL
          SQL
          now,
          now,
        ]
      ) == 1
    else
      scope.update_all(next_index: position + 1, lease_expires_at: now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE, updated_at: now) == 1
    end
  end

  def skip_to!(token, cursor, now: Time.current)
    return false if cursor <= next_index

    scope = owned_scope(token).where('next_index < ?', cursor)
    if cursor >= item_count
      scope.update_all(
        [
          <<~SQL.squish,
            next_index = ?,
            updated_at = ?,
            state = CASE WHEN isolated_positions = '[]'::jsonb AND retry_positions = '[]'::jsonb THEN 'complete' ELSE 'incomplete' END,
            completed_at = ?::timestamp,
            lease_token = NULL,
            lease_expires_at = NULL
          SQL
          item_count,
          now,
          now,
        ]
      ) == 1
    else
      scope.update_all(next_index: cursor, lease_expires_at: now + ExternalBridge::RSS::Limits::SNAPSHOT_LEASE, updated_at: now) == 1
    end
  end

  private

  def owned_scope(token)
    self.class.where(id: id, lease_token: token, state: OPEN_STATES)
  end

  def isolated_entry(entry)
    if entry.is_a?(Hash)
      position = entry['position'] || entry[:position]
      return nil if position.nil?

      { 'position' => position.to_i, 'code' => (entry['code'] || entry[:code] || 'snapshot_failed').to_s }
    else
      { 'position' => entry.to_i, 'code' => 'snapshot_failed' }
    end
  end
end
