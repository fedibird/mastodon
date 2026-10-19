# frozen_string_literal: true

# == Schema Information
#
# Table name: external_status_projections
#
#  id                       :bigint(8)        not null, primary key
#  user_id                  :bigint(8)        not null
#  account_id               :bigint(8)        not null
#  external_source_id       :bigint(8)        not null
#  external_subscription_id :bigint(8)        not null
#  external_resource_id     :bigint(8)        not null
#  status_id                :bigint(8)        not null
#  last_seen_revision       :text
#  source_deleted           :boolean          default(FALSE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
class ExternalStatusProjection < ApplicationRecord
  belongs_to :user
  belongs_to :account
  belongs_to :external_source
  belongs_to :external_subscription
  belongs_to :external_resource
  belongs_to :status

  after_commit :remove_from_search_index, on: [:create, :update]

  private

  def remove_from_search_index
    return unless Chewy.enabled?

    Chewy.strategy.current.update(StatusesIndex, [status_id])
  rescue StandardError => e
    Rails.logger.warn("[ExternalBridge] search delete failed status=#{status_id}: #{e.class}")
  end
end
