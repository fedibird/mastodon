# frozen_string_literal: true

# == Schema Information
#
# Table name: moderation_rejection_events
#
#  id                             :bigint(8)        not null, primary key
#  rejector_subject_id            :bigint(8)
#  rejected_subject_id            :bigint(8)
#  event_type                     :integer          not null
#  preceding_interaction_event_id :bigint(8)
#  occurred_at                    :datetime         not null
#  observed_at                    :datetime         not null
#  metadata                       :jsonb            not null
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#
# An observed negative/rejection signal returned by the contacted side
# (follow reject, remove follower, mute, mute notifications, block, report).
#
# "Doing nothing" is never recorded as a positive signal. When possible the
# recorder links back to the interaction that immediately preceded the
# rejection via +preceding_interaction_event+ so time-to-rejection can be
# analysed later.
class ModerationRejectionEvent < ApplicationRecord
  self.table_name = 'moderation_rejection_events'

  enum event_type: {
    follow_reject: 0,
    remove_follower: 1,
    mute: 2,
    mute_notifications: 3,
    block: 4,
    report: 5,
  }, _suffix: :event

  belongs_to :rejector_subject, class_name: 'ModerationSubject', inverse_of: :rejections_made, optional: true
  belongs_to :rejected_subject, class_name: 'ModerationSubject', inverse_of: :rejections_received, optional: true
  belongs_to :preceding_interaction_event, class_name: 'ModerationInteractionEvent', optional: true, inverse_of: :caused_rejections

  validates :event_type, presence: true
  validates :occurred_at, :observed_at, presence: true

  # Seconds between the preceding contact and this rejection, when known.
  def time_to_rejection
    return nil if preceding_interaction_event.nil?

    occurred_at - preceding_interaction_event.occurred_at
  end
end
