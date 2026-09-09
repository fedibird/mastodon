# frozen_string_literal: true

# == Schema Information
#
# Table name: moderation_evidence_snapshots
#
#  id             :bigint(8)        not null, primary key
#  subject_id     :bigint(8)        not null
#  window_start   :datetime
#  window_end     :datetime
#  summary        :jsonb            not null
#  fingerprint    :jsonb            not null
#  schema_version :integer          default(1), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# A point-in-time evidence snapshot for a moderation subject, generated when a
# moderator action is taken. It fixes the reasoning behind an action so it can
# be reviewed later even after the underlying records are gone, and provides a
# baseline for comparing behaviour after a suspension.
#
# +summary+ holds scalar counts; +fingerprint+ holds sets such as the linked
# negative-target set (preceding-contact association) and the weaker
# same-window correlation set. +schema_version+ tracks the shape of those
# payloads.
class ModerationEvidenceSnapshot < ApplicationRecord
  self.table_name = 'moderation_evidence_snapshots'

  belongs_to :subject, class_name: 'ModerationSubject'

  has_many :moderation_actions, class_name: 'ModerationAction', foreign_key: :evidence_snapshot_id, inverse_of: :evidence_snapshot, dependent: :nullify

  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }

  # Strong temporal/linked association via preceding_interaction_event_id.
  # Not proof that the rejection was caused by that contact.
  def linked_negative_target_subject_ids
    Array(fingerprint['linked_negative_target_subject_ids'].presence || fingerprint['negative_target_subject_ids'])
  end

  # Same-window overlap without a preceding-contact link. Must not be treated
  # as a linked negative-target set.
  def correlated_negative_target_subject_ids
    Array(fingerprint['correlated_negative_target_subject_ids'])
  end
end

