# frozen_string_literal: true

# == Schema Information
#
# Table name: moderation_actions
#
#  id                   :bigint(8)        not null, primary key
#  subject_id           :bigint(8)        not null
#  action_type          :integer          not null
#  performed_at         :datetime         not null
#  moderator_account_id :bigint(8)
#  reason_code          :string
#  evidence_snapshot_id :bigint(8)
#  metadata             :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
# A moderator action taken against a subject (warn/limit/freeze/suspend/delete/
# other), with an optional link to the evidence snapshot captured at the time.
# Kept independently of Mastodon's own moderation records so the history
# survives account/report deletion.
class ModerationAction < ApplicationRecord
  self.table_name = 'moderation_actions'

  enum action_type: {
    warn: 0,
    limit: 1,
    freeze: 2,
    suspend: 3,
    delete: 4,
    other: 5,
  }, _suffix: :action

  belongs_to :subject, class_name: 'ModerationSubject'
  belongs_to :moderator_account, class_name: 'Account', optional: true
  belongs_to :evidence_snapshot, class_name: 'ModerationEvidenceSnapshot', optional: true

  validates :action_type, presence: true
  validates :performed_at, presence: true
end
