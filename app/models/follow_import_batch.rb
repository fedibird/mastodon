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

  belongs_to :subject, class_name: 'ModerationSubject'

  has_many :targets, class_name: 'FollowImportTarget', foreign_key: :batch_id, inverse_of: :batch, dependent: :destroy

  validates :imported_at, presence: true
  validates :target_count, :resolved_target_count, :unresolved_target_count, numericality: { greater_than_or_equal_to: 0 }
  validates :import_id, uniqueness: { allow_nil: true }

  COMPLETION_NOTIFIED_KEY = 'completion_notified_at'
  EXECUTOR_ENQUEUED_KEY   = 'executor_enqueued_at'

  # Recent batches whose completion has not yet been notified. Bounded by an
  # imported_at window so the completion sweeper never rescans abandoned/never-
  # completing batches forever. `metadata` is not indexed for this predicate, but
  # the imported_at window keeps the candidate set small.
  scope :awaiting_completion_notification, ->(since) {
    where('(metadata ->> :key) IS NULL', key: COMPLETION_NOTIFIED_KEY).where('imported_at >= ?', since)
  }

  def for_account
    subject&.account
  end

  def completion_notified?
    metadata[COMPLETION_NOTIFIED_KEY].present?
  end

  def mark_completion_notified!(at = Time.now.utc)
    update!(metadata: metadata.merge(COMPLETION_NOTIFIED_KEY => at.utc.iso8601))
  end

  # True once the batch executor (FollowImport::BatchExecutionWorker) has been
  # successfully enqueued. From that point the executor owns the import's
  # lifecycle — it re-reads the CSV to resolve target addresses/options and
  # destroys the import when dispatch completes — so any other import cleanup
  # (e.g. ImportWorker's retries-exhausted path) must NOT delete the CSV.
  def executor_enqueued?
    metadata[EXECUTOR_ENQUEUED_KEY].present?
  end

  def mark_executor_enqueued!(at = Time.now.utc)
    update!(metadata: metadata.merge(EXECUTOR_ENQUEUED_KEY => at.utc.iso8601))
  end
end
