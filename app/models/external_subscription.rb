# frozen_string_literal: true

# == Schema Information
#
# Table name: external_subscriptions
#
#  id                 :bigint(8)        not null, primary key
#  user_id            :bigint(8)        not null
#  external_source_id :bigint(8)        not null
#  state              :string           default("active"), not null
#  last_error_code    :string
#  last_error_at      :datetime
#  checked_at         :datetime
#  next_retry_at      :datetime
#  retry_count        :integer          default(0), not null
#  failed_item_count  :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class ExternalSubscription < ApplicationRecord
  STATES = %w(active paused error).freeze

  belongs_to :user
  belongs_to :external_source
  has_many :external_status_projections, dependent: :restrict_with_exception
  has_many :external_projection_failures, dependent: :destroy

  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: 'active') }
end
