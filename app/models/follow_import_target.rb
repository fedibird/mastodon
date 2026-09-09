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
#
# A single target within a follow-import batch. `target_subject` is set when the
# imported account address resolves to a known account at import time; otherwise
# `target_key_hash` holds a pseudonymous stable key for the unresolved address.
class FollowImportTarget < ApplicationRecord
  self.table_name = 'follow_import_targets'

  belongs_to :batch, class_name: 'FollowImportBatch', inverse_of: :targets
  belongs_to :target_subject, class_name: 'ModerationSubject', optional: true

  validates :target_subject_id, presence: true, unless: -> { target_key_hash.present? }

  def resolved?
    target_subject_id.present?
  end
end
