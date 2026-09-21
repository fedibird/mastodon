# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_batches
#
#  id                      :bigint(8)        not null, primary key
#  subject_id              :bigint(8)        not null
#  import_id               :bigint(8)
#  imported_at             :datetime         not null
#  mode                    :integer          default("unknown"), not null
#  target_count            :integer          default(0), not null
#  resolved_target_count   :integer          default(0), not null
#  unresolved_target_count :integer          default(0), not null
#  account_age_seconds     :bigint(8)
#  migration_evidence      :integer          default("none"), not null
#  metadata                :jsonb            not null
#  dispatch_owner          :integer          default("legacy"), not null
#  dispatch_cohort         :integer          default("historical"), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#
# A single follow-import event, recorded before the follows are executed.
#
# Follow import is an especially valuable observation point because the entire
# target set is presented to the server up front. The batch stores the summary
# (counts, mode, account age, migration evidence) and its `targets` capture the
# individual contacted accounts.
class FollowImportBatch < ApplicationRecord
  self.table_name = 'follow_import_batches'

  enum mode: { unknown: 0, merge: 1, overwrite: 2 }, _suffix: :mode
  enum migration_evidence: { none: 0, weak: 1, strong: 2 }, _prefix: :migration
  enum dispatch_owner: { legacy: 0, scheduler: 1 }, _suffix: :dispatch_owner
  enum dispatch_cohort: { historical: 0, operational: 1 }, _suffix: :dispatch_cohort

  belongs_to :subject, class_name: 'ModerationSubject'

  has_many :targets, class_name: 'FollowImportTarget', foreign_key: :batch_id, inverse_of: :batch, dependent: :destroy

  validates :imported_at, presence: true
  validates :target_count, :resolved_target_count, :unresolved_target_count, numericality: { greater_than_or_equal_to: 0 }
  validates :import_id, uniqueness: { allow_nil: true }
  validates :dispatch_owner, inclusion: { in: dispatch_owners.keys }
  validates :dispatch_cohort, inclusion: { in: dispatch_cohorts.keys }

  scope :scheduler_owned, -> { scheduler_dispatch_owner }
  scope :legacy_owned, -> { legacy_dispatch_owner }
  scope :historical_cohort, -> { historical_dispatch_cohort }
  scope :operational_cohort, -> { operational_dispatch_cohort }

  # SHADOW may plan/observe every operational batch, including those
  # still owned by the legacy worker while GLOBAL is off.
  def self.shadow_planning_scope
    operational_cohort
  end

  # GLOBAL may claim only the intersection of operational provenance
  # and scheduler ownership. A historical scheduler-owned row is not
  # live work.
  def self.global_planning_scope
    operational_cohort.scheduler_owned
  end

  COMPLETED_AT_KEY        = 'completed_at'
  COMPLETION_NOTIFIED_KEY = 'completion_notified_at'

  # Un-notified batches that are eligible for a completion email. Bounded by a
  # completion signal, never by imported_at: PR C can leave targets pending for
  # a later recheck, so a batch may validly finish long after import. Candidates
  # are either already persisted as complete, or recently settled (every target
  # terminal and the latest target completion is inside +since+). Never-finishing
  # batches stay out of both sets.
  scope :awaiting_completion_notification, ->(since) {
    where('(metadata ->> :notified) IS NULL', notified: COMPLETION_NOTIFIED_KEY)
      .merge(
        where('(metadata ->> :completed) IS NOT NULL', completed: COMPLETED_AT_KEY)
          .or(where(id: recently_settled_batch_ids(since)))
      )
  }

  def self.recently_settled_batch_ids(since)
    terminal = FollowImportTarget.states.values_at(*FollowImportTarget::TERMINAL_STATES)
    FollowImportTarget
      .group(:batch_id)
      .having('COUNT(*) > 0')
      .having('SUM(CASE WHEN state NOT IN (?) THEN 1 ELSE 0 END) = 0', terminal)
      .having('MAX(COALESCE(completed_at, updated_at)) >= ?', since)
      .select(:batch_id)
  end

  def for_account
    subject&.account
  end

  def completion_recorded?
    metadata[COMPLETED_AT_KEY].present?
  end

  def completion_notified?
    metadata[COMPLETION_NOTIFIED_KEY].present?
  end

  # Durable "this batch has finished" mark. Written when the last target becomes
  # terminal (and as a sweeper backfill) so a late finish stays email-eligible
  # even after the recent-settlement lookback. Does not overwrite a first time.
  def record_completion!(at = Time.now.utc)
    return if completion_recorded?

    update!(metadata: metadata.merge(COMPLETED_AT_KEY => at.utc.iso8601))
  end

  def record_completion_if_settled!(at = Time.now.utc)
    with_lock do
      return if completion_recorded?
      return unless targets.exists?
      return if targets.non_terminal.exists?

      record_completion!(at)
    end
  end

  def mark_completion_notified!(at = Time.now.utc)
    update!(metadata: metadata.merge(COMPLETION_NOTIFIED_KEY => at.utc.iso8601))
  end
end
