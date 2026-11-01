# frozen_string_literal: true

# One attempt to follow a newly approved local group from its founding
# owner. The row is created with the approval and is not backfilled onto
# older groups. relationship_recorded_at is the discharge latch: once it
# is set, a missing follow means the person undid it and must not be
# followed again. Owner role and this follow are separate facts.
class GroupInitialFollow < ApplicationRecord
  LEASE = 2.minutes
  MAX_ATTEMPTS = 8
  LOCK_NAMESPACE = 1_683_021

  enum state: {
    pending: 0,
    processing: 1,
    succeeded: 2,
    retryable_failure: 3,
    completed: 4,
    permanent_failure: 5,
  }

  TRANSITIONS = {
    'pending' => %w(processing),
    'processing' => %w(succeeded completed retryable_failure permanent_failure pending),
    'retryable_failure' => %w(processing pending),
    'permanent_failure' => %w(pending),
    'succeeded' => [],
    'completed' => [],
  }.freeze

  belongs_to :group_creation_request, inverse_of: :initial_follow
  belongs_to :follow, optional: true
  belongs_to :follow_request, optional: true

  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :outcome, :last_error, format: { with: /\A[a-z0-9_]{1,64}\z/ }, allow_nil: true
  validate :request_is_approved, on: :create
  validate :state_transition, on: :update
  validate :discharge_is_permanent, on: :update

  def discharged?
    relationship_recorded_at.present?
  end

  def terminal?
    succeeded? || completed? || permanent_failure?
  end

  def claim_held?
    processing? && claim_expires_at.present? && claim_expires_at.future?
  end

  # True when a Follow or FollowRequest between the founding owner and the
  # group still exists. The stored ids are not foreign keys and may point
  # at a row the person has already removed.
  def relationship_still_present?
    owner = group_creation_request&.initial_owner_account
    group = group_creation_request&.group_account
    return false if owner.nil? || group.nil?

    Follow.where(account_id: owner.id, target_account_id: group.id).exists? ||
      FollowRequest.where(account_id: owner.id, target_account_id: group.id).exists?
  end

  def self.recovery_request_ids
    stale_before = 30.seconds.ago
    pending_ids = where(state: [:pending, :retryable_failure])
                  .where(arel_table[:updated_at].lt(stale_before))
                  .order(:id)
                  .limit(20)
                  .pluck(:group_creation_request_id)
    processing_ids = where(state: :processing)
                     .where('claim_expires_at IS NULL OR claim_expires_at < ?', Time.current)
                     .order(:id)
                     .limit(20)
                     .pluck(:group_creation_request_id)
    (pending_ids + processing_ids).uniq.first(20)
  end

  private

  def request_is_approved
    errors.add(:group_creation_request, :invalid) unless group_creation_request&.approved?
  end

  def state_transition
    return unless will_save_change_to_state?

    from = self.class.states.key(state_in_database) || state_in_database.to_s
    allowed = TRANSITIONS.fetch(from.to_s, [])
    errors.add(:state, :invalid) unless allowed.include?(state.to_s)
  end

  def discharge_is_permanent
    return unless will_save_change_to_relationship_recorded_at?
    return if relationship_recorded_at_in_database.nil?

    errors.add(:relationship_recorded_at, :immutable)
  end
end
