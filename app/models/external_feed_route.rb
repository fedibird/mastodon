# frozen_string_literal: true

# == Schema Information
#
# Table name: external_feed_routes
#
#  id                       :bigint(8)        not null, primary key
#  user_id                  :bigint(8)        not null
#  external_subscription_id :bigint(8)        not null
#  destination              :string           not null
#  list_id                  :bigint(8)
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
class ExternalFeedRoute < ApplicationRecord
  DESTINATIONS = %w(home list).freeze

  belongs_to :user
  belongs_to :external_subscription
  belongs_to :list, optional: true, inverse_of: :external_feed_routes

  validates :destination, inclusion: { in: DESTINATIONS }
  validate :destination_shape

  private

  def destination_shape
    if destination == 'home' && list_id.present?
      errors.add(:list_id, :present)
    elsif destination == 'list' && list_id.blank?
      errors.add(:list_id, :blank)
    end
  end
end
