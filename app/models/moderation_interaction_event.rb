# frozen_string_literal: true

# == Schema Information
#
# Table name: moderation_interaction_events
#
#  id                 :bigint(8)        not null, primary key
#  actor_subject_id   :bigint(8)        not null
#  target_subject_id  :bigint(8)        not null
#  event_type         :integer          not null
#  status_id          :bigint(8)
#  source_record_type :string
#  source_record_id   :bigint(8)
#  import_batch_id    :bigint(8)
#  occurred_at        :datetime         not null
#  observed_at        :datetime         not null
#  metadata           :jsonb            not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# An observed contact from one subject to another (mention, reply, follow,
# quote, reference, reaction, favourite, follow import).
#
# This is an append-only observation ledger: a single interaction is not judged
# good or bad here. +status_id+/+source_record_id+ are non-foreign-key pointers
# kept only for short-term investigation, so deleting the source never removes
# the recorded event.
class ModerationInteractionEvent < ApplicationRecord
  self.table_name = 'moderation_interaction_events'

  enum event_type: {
    mention: 0,
    reply: 1,
    follow: 2,
    quote: 3,
    reference: 4,
    reaction: 5,
    favourite: 6,
    follow_import: 7,
  }, _suffix: :event

  belongs_to :actor_subject, class_name: 'ModerationSubject', inverse_of: :actor_interaction_events
  belongs_to :target_subject, class_name: 'ModerationSubject', inverse_of: :target_interaction_events

  has_many :caused_rejections,
           class_name: 'ModerationRejectionEvent',
           foreign_key: :preceding_interaction_event_id,
           inverse_of: :preceding_interaction_event,
           dependent: :nullify

  validates :event_type, presence: true
  validates :occurred_at, :observed_at, presence: true

  scope :between, ->(actor_subject, target_subject) { where(actor_subject: actor_subject, target_subject: target_subject) }
end
