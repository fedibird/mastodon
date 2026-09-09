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
end
