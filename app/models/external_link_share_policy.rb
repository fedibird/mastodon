# frozen_string_literal: true

# == Schema Information
#
# Table name: external_link_share_policies
#
#  id           :bigint(8)        not null, primary key
#  user_id      :bigint(8)        not null
#  enabled      :boolean          default(FALSE), not null
#  visibility   :string           default("unlisted"), not null
#  revision     :integer          default(0), not null
#  consented_at :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class ExternalLinkSharePolicy < ApplicationRecord
  VISIBILITIES = %w(public unlisted).freeze

  belongs_to :user, inverse_of: :external_link_share_policy

  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :consent_present_when_enabled

  private

  def consent_present_when_enabled
    errors.add(:consented_at, :blank) if enabled? && consented_at.nil?
  end
end
