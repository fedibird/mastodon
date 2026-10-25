# frozen_string_literal: true

# == Schema Information
#
# Table name: external_projection_link_boosts
#
#  id                            :bigint(8)        not null, primary key
#  user_id                       :bigint(8)        not null
#  account_id                    :bigint(8)        not null
#  link_reference_id             :bigint(8)        not null
#  external_status_projection_id :bigint(8)
#  projection_status_id          :bigint(8)        not null
#  reference_status_id           :bigint(8)
#  wrapper_status_id             :bigint(8)
#  visibility                    :string           not null
#  generation                    :integer          not null
#  policy_revision               :integer          not null
#  state                         :string           default("active"), not null
#  ended_reason                  :string
#  announced_at                  :datetime
#  announce_enqueued_at          :datetime
#  next_announce_at              :datetime
#  undone_at                     :datetime
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  removal_acknowledged_at       :datetime
#  removal_next_attempt_at       :datetime
#

# One share generation of a projection by one User. The wrapper Status is an
# ordinary boost of the reference note on the User's Account. This row is what
# says the wrapper belongs to this User for this projection. Looking the
# wrapper up by Account and reference Status is not a substitute, because a
# second User of the same Account would then read or undo the first one's
# share.
class ExternalProjectionLinkBoost < ApplicationRecord
  STATES = %w(active undone).freeze
  VISIBILITIES = %w(public unlisted).freeze

  belongs_to :user, inverse_of: :external_projection_link_boosts
  belongs_to :account
  belongs_to :link_reference, class_name: 'ExternalProjectionLinkReference', inverse_of: :boosts
  belongs_to :external_status_projection, optional: true
  belongs_to :reference_status, class_name: 'Status', optional: true
  belongs_to :wrapper_status, class_name: 'Status', optional: true

  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: 'active') }

  def active?
    state == 'active'
  end

  def undone?
    state == 'undone'
  end

  # The intent is committed. An Undo must be sent when this row ends.
  def announced?
    announced_at.present?
  end

  # The ActivityPub job was accepted by Sidekiq.
  def announce_enqueued?
    announce_enqueued_at.present?
  end
end
