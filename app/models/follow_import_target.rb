# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_targets
#
#  id                       :bigint(8)        not null, primary key
#  batch_id                 :bigint(8)        not null
#  target_subject_id        :bigint(8)
#  target_key_hash          :string
#  position                 :integer
#  prior_relationship_state :jsonb
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  state                    :integer          default("pending"), not null
#  follow_request_uri       :string
#  queued_at                :datetime
#  delivered_at             :datetime
#  response_deadline_at     :datetime
#  completed_at             :datetime
#  delivery_attempts        :integer          default(0), not null
#  failure_code             :string
#
# A single target within a follow-import batch. `target_subject` is set when the
# imported account address resolves to a known account at import time; otherwise
# `target_key_hash` holds a pseudonymous stable key for the unresolved address.
# The execution-state columns track per-target progress once controlled
# execution lands; the DB is the source of truth (not the Sidekiq queue).
class FollowImportTarget < ApplicationRecord
  self.table_name = 'follow_import_targets'

  # Per-target execution state (DB is the source of truth for progress; the
  # Sidekiq queue is NOT treated as business state). Legacy rows default to
  # +pending+. delivery succeeded != follow accepted; no response != rejected;
  # completed_no_response only means "our import processing wait is finished".
  # Transitions must go through Moderation-free FollowImport::TargetTransitionService.
  # INVARIANT: follow_request_uri and state (>= queued) must be persisted BEFORE
  # the ActivityPub Follow is enqueued for delivery, so an inbound Accept/Reject
  # always has a target to correlate to (it may race ahead of delivery bookkeeping).
  enum state: {
    pending: 0,
    queued: 1,
    awaiting_delivery: 2,
    awaiting_response: 3,
    accepted: 4,
    rejected: 5,
    completed_no_response: 6,
    delivery_failed: 7,
  }, _prefix: :state

  # A target is done (for import-processing purposes) in any of these; a terminal
  # result must never be overwritten by a late/duplicate callback.
  TERMINAL_STATES = %w(accepted rejected completed_no_response delivery_failed).freeze

  belongs_to :batch, class_name: 'FollowImportBatch', inverse_of: :targets
  belongs_to :target_subject, class_name: 'ModerationSubject', optional: true

  validates :target_subject_id, presence: true, unless: -> { target_key_hash.present? }

  scope :terminal, -> { where(state: TERMINAL_STATES) }
  scope :non_terminal, -> { where.not(state: TERMINAL_STATES) }
  # Targets whose response wait has elapsed (for a future periodic sweeper).
  scope :response_overdue, ->(now = Time.now.utc) { where(state: :awaiting_response).where('response_deadline_at IS NOT NULL AND response_deadline_at <= ?', now) }

  def resolved?
    target_subject_id.present?
  end

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  # Canonical, deterministic key for an imported account address, used both to
  # deduplicate the target set at record time and to correlate an execution unit
  # (Import::RelationshipWorker follow) back to its exact target row. Normalizes
  # username/domain case and defaults a bare (local) address to the local domain,
  # so "alice", "Alice", and "alice@<local_domain>" all map to the same key.
  # Returns nil for a blank/invalid address.
  def self.key_hash(acct)
    username, domain = acct.to_s.strip.split('@', 2)
    return if username.blank?

    domain = Rails.configuration.x.local_domain if domain.blank?
    Digest::SHA256.hexdigest("#{username.downcase}@#{domain.to_s.downcase}")
  end
end
