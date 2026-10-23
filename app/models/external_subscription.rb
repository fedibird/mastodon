# frozen_string_literal: true

# == Schema Information
#
# Table name: external_subscriptions
#
#  id                   :bigint(8)        not null, primary key
#  user_id              :bigint(8)        not null
#  external_source_id   :bigint(8)        not null
#  state                :string           default("active"), not null
#  last_error_code      :string
#  last_error_at        :datetime
#  checked_at           :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  next_retry_at        :datetime
#  retry_count          :integer          default(0), not null
#  failed_item_count    :integer          default(0), not null
#  feed_routes_revision :bigint(8)        default(0), not null
#
# A row is due when its own next_retry_at has arrived, or, when that column is
# empty, when checked_at is empty or older than the public-cache freshness
# window. Another subscriber of the same source does not make this row due.
# feed_routes_revision moves only when the route set changes.
class ExternalSubscription < ApplicationRecord
  STATES = %w(active paused error).freeze

  belongs_to :user
  belongs_to :external_source
  has_many :external_status_projections, dependent: :restrict_with_exception
  has_many :external_projection_failures, dependent: :destroy
  has_many :external_feed_routes, dependent: :delete_all

  validates :state, inclusion: { in: STATES }

  # Runs before dependent: :delete_all, which is also a before_destroy.
  before_destroy :schedule_external_feed_removed, prepend: true

  scope :active, -> { where(state: 'active') }

  scope :due_for_refresh, lambda {
    where(
      <<~SQL.squish,
        (external_subscriptions.next_retry_at IS NOT NULL AND external_subscriptions.next_retry_at <= :now)
        OR (
          external_subscriptions.next_retry_at IS NULL
          AND (external_subscriptions.checked_at IS NULL OR external_subscriptions.checked_at < :cutoff)
        )
      SQL
      now: Time.current,
      cutoff: ExternalBridge::RSS::Limits::FRESH_FOR.ago
    )
  }

  private

  def schedule_external_feed_removed
    targets = external_feed_routes.filter_map { |route| external_feed_target(route) }
    return if targets.empty?

    ExternalBridge::Streaming::Scheduler.schedule_control!(
      user_id: user_id,
      subscription_id: id,
      reason: 'subscription_removed',
      revision: feed_routes_revision,
      targets: targets
    )
  end

  def external_feed_target(route)
    return { 'type' => 'home' } if route.destination == 'home'
    return nil if route.list_id.blank?

    { 'type' => 'list', 'id' => route.list_id.to_s }
  end
end
