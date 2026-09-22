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
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  dispatch_owner          :integer          default("legacy"), not null
#  dispatch_cohort         :integer          default("historical"), not null
#  preflight_state         :integer          default("ready"), not null
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
  enum preflight_state: { screening: 0, ready: 1, review_required: 2, stopped: 3 }, _suffix: :preflight_state

  belongs_to :subject, class_name: 'ModerationSubject'

  has_many :targets, class_name: 'FollowImportTarget', foreign_key: :batch_id, inverse_of: :batch, dependent: :destroy

  validates :imported_at, presence: true
  validates :target_count, :resolved_target_count, :unresolved_target_count, numericality: { greater_than_or_equal_to: 0 }
  validates :import_id, uniqueness: { allow_nil: true }
  validates :dispatch_owner, inclusion: { in: dispatch_owners.keys }
  validates :dispatch_cohort, inclusion: { in: dispatch_cohorts.keys }
  validates :preflight_state, inclusion: { in: preflight_states.keys }

  scope :scheduler_owned, -> { scheduler_dispatch_owner }
  scope :legacy_owned, -> { legacy_dispatch_owner }
  scope :historical_cohort, -> { historical_dispatch_cohort }
  scope :operational_cohort, -> { operational_dispatch_cohort }

  # SHADOW may plan/observe ready operational batches, including those
  # still owned by the legacy worker while GLOBAL is off. Screening /
  # review_required / stopped rows stay in operational provenance
  # counts but are not executable planning work.
  def self.shadow_planning_scope
    operational_cohort.ready_preflight_state
  end

  # GLOBAL may claim only the intersection of operational provenance,
  # scheduler ownership, and ready preflight. A historical
  # scheduler-owned row is not live work. A screening row is not
  # executable until released.
  def self.global_planning_scope
    operational_cohort.scheduler_owned.ready_preflight_state
  end

  # Authoritative GLOBAL claim predicate. Planner scope is not enough:
  # DispatchExecutor re-checks owner, cohort, and preflight at the
  # mutation boundary. A historical or non-ready scheduler-owned row
  # is not executable.
  def globally_claimable?
    operational_dispatch_cohort? && scheduler_dispatch_owner? && ready_preflight_state?
  end

  COMPLETED_AT_KEY               = 'completed_at'
  COMPLETION_NOTIFIED_KEY        = 'completion_notified_at'
  REVIEW_RESUME_REQUIRED_AT_KEY  = 'review_resume_required_at'
  REVIEW_RESUME_COMPLETED_AT_KEY = 'review_resume_completed_at'
  REVIEW_SIGNAL_SHADOW_V1_KEY    = 'review_signal_shadow_v1'

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
  # The row is reloaded under lock so a stale copy cannot drop resume keys.
  def record_completion!(at = Time.now.utc)
    with_lock do
      reload
      return if completion_recorded?

      write_merged_metadata!({ COMPLETED_AT_KEY => at.utc.iso8601 })
    end
  end

  def record_completion_if_settled!(at = Time.now.utc)
    with_lock do
      reload
      return if completion_recorded?
      return unless targets.exists?
      return if targets.non_terminal.exists?

      write_merged_metadata!({ COMPLETED_AT_KEY => at.utc.iso8601 })
    end
  end

  def mark_completion_notified!(at = Time.now.utc)
    merge_metadata!({ COMPLETION_NOTIFIED_KEY => at.utc.iso8601 })
  end

  # Post-approval handoff bookkeeping. required_at is written in the same
  # update that moves review_required -> ready. completed_at is written
  # only after the resume worker finishes its at-least-once handoff.
  # While required and not completed, the raw CSV must stay available.
  # Metadata writes reload under the row lock. Completion and resume
  # markers share this jsonb column, so a stale whole-hash write would
  # drop the other marker and break CSV retention or resume recovery.
  def review_resume_required?
    metadata[REVIEW_RESUME_REQUIRED_AT_KEY].present?
  end

  def review_resume_completed?
    metadata[REVIEW_RESUME_COMPLETED_AT_KEY].present?
  end

  def review_resume_pending?
    review_resume_required? && !review_resume_completed?
  end

  # Joins an already-open transaction. Approve holds this row, then calls
  # here, so ready and review_resume_required_at commit with the request.
  def mark_review_resume_required!(at = Time.now.utc)
    merge_metadata!(
      { REVIEW_RESUME_REQUIRED_AT_KEY => at.utc.iso8601 },
      preflight_state: :ready
    )
  end

  def mark_review_resume_completed!(at = Time.now.utc)
    with_lock do
      reload
      return if review_resume_completed?

      write_merged_metadata!({ REVIEW_RESUME_COMPLETED_AT_KEY => at.utc.iso8601 })
    end
  end

  # First successful shadow observation wins. A stale copy reloads under
  # the row lock before merging, so completion and resume keys stay put.
  # v2 must use a different key. This write does not change preflight_state.
  def review_signal_shadow_v1
    metadata[REVIEW_SIGNAL_SHADOW_V1_KEY]
  end

  def review_signal_shadow_v1_recorded?
    review_signal_shadow_v1.present?
  end

  def record_review_signal_shadow_v1!(payload)
    with_lock do
      reload
      return if review_signal_shadow_v1_recorded?

      write_merged_metadata!({ REVIEW_SIGNAL_SHADOW_V1_KEY => payload })
    end
  end

  private

  # Lock, reload, then merge. Callers that already hold the row lock use
  # write_merged_metadata! so record_completion_if_settled! does not nest
  # another lock around the same write.
  def merge_metadata!(attrs, **columns)
    with_lock do
      write_merged_metadata!(attrs, **columns)
    end
  end

  def write_merged_metadata!(attrs, **columns)
    reload
    update!(columns.merge(metadata: metadata.merge(attrs)))
  end
end
