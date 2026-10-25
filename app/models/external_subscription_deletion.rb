# frozen_string_literal: true

# == Schema Information
#
# Table name: external_subscription_deletions
#
#  id                       :bigint(8)        not null, primary key
#  user_id                  :bigint(8)        not null
#  external_subscription_id :bigint(8)        not null
#  external_source_id       :bigint(8)        not null
#  state                    :string           default("queued"), not null
#  total_count              :bigint(8)
#  deleted_count            :bigint(8)        default(0), not null
#  route_targets            :jsonb            not null
#  attempt_count            :integer          default(0), not null
#  last_error_code          :string
#  next_run_at              :datetime
#  requested_at             :datetime         not null
#  started_at               :datetime
#  last_progress_at         :datetime
#  finished_at              :datetime
#  control_enqueued_at      :datetime
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
# Owner-visible progress of one asynchronous unsubscribe. The subscription row
# is destroyed as the last step, so external_subscription_id is not a foreign
# key and this record outlives it. It never holds a feed URL, feed text, a
# token, or an exception message. Per-status cache, search, and stream work
# lives on external_subscription_deletion_effects, not on this row.
class ExternalSubscriptionDeletion < ApplicationRecord
  STATES = %w(queued running completed failed).freeze
  RETENTION = 30.days
  # Rate samples shorter than this say nothing about the real speed.
  MIN_RATE_WINDOW = 2.0

  belongs_to :user
  has_many :effects, class_name: 'ExternalSubscriptionDeletionEffect', dependent: :delete_all

  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: %w(queued running failed)) }
  scope :owned_by, ->(user) { where(user_id: user.id) }

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end

  def preparing?
    total_count.nil? && !completed?
  end

  def remaining
    return 0 if completed?
    return nil if total_count.nil?

    [total_count - deleted_count, 0].max
  end

  # Never 100 before the record is completed: the subscription row is still
  # there until the finishing transaction has run.
  def percent
    return 100 if completed?
    return nil if total_count.nil?
    return 99 if total_count.zero?

    [(deleted_count * 100 / total_count), 99].min
  end

  # Whole seconds, only from a speed observed on real deleted rows. nil means
  # "calculating".
  def eta_seconds
    return nil unless running?

    left = remaining
    return nil if left.nil? || deleted_count <= 0 || started_at.nil? || last_progress_at.nil?
    return 0 if left.zero?

    elapsed = last_progress_at - started_at
    return nil if elapsed < MIN_RATE_WINDOW

    (left / (deleted_count / elapsed)).ceil
  end

  # A failed record with a next_run_at is picked up again by the recovery
  # scheduler on its own. Only a failed record without one (attempts used up)
  # waits for the owner.
  def auto_retrying?
    failed? && next_run_at.present?
  end

  def terminal_failed?
    failed? && next_run_at.nil?
  end

  def retryable?
    terminal_failed?
  end

  # Something will still change without the owner doing anything.
  def in_flight?
    queued? || running? || auto_retrying?
  end
end
