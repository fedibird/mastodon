# frozen_string_literal: true

# == Schema Information
#
# Table name: external_projection_link_references
#
#  id                             :bigint(8)        not null, primary key
#  user_id                        :bigint(8)        not null
#  account_id                     :bigint(8)        not null
#  external_status_projection_id  :bigint(8)
#  projection_status_id           :bigint(8)        not null
#  reference_status_id            :bigint(8)
#  visibility                     :string           not null
#  canonical_url                  :text             not null
#  resource_revision              :text
#  policy_revision                :integer          not null
#  state                          :string           default("active"), not null
#  superseded_at                  :datetime
#  published_at                   :datetime
#  next_recovery_at               :datetime
#  reference_digest               :string(64)
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#

class ExternalProjectionLinkReference < ApplicationRecord
  STATES = %w(active superseded broken).freeze
  VISIBILITIES = %w(public unlisted).freeze

  belongs_to :user, inverse_of: :external_projection_link_references
  belongs_to :account
  belongs_to :external_status_projection, optional: true, inverse_of: :external_projection_link_references
  belongs_to :reference_status, class_name: 'Status', optional: true
  has_many :boosts, class_name: 'ExternalProjectionLinkBoost', foreign_key: :link_reference_id, inverse_of: :link_reference, dependent: :delete_all

  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :state, inclusion: { in: STATES }
  validates :canonical_url, presence: true

  def active?
    state == 'active'
  end

  def broken?
    state == 'broken'
  end
end
