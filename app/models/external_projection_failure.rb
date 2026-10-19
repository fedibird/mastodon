# frozen_string_literal: true

# == Schema Information
#
# Table name: external_projection_failures
#
#  id                       :bigint(8)        not null, primary key
#  user_id                  :bigint(8)        not null
#  external_subscription_id :bigint(8)        not null
#  external_resource_id     :bigint(8)        not null
#  error_code               :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
class ExternalProjectionFailure < ApplicationRecord
  belongs_to :user
  belongs_to :external_subscription
  belongs_to :external_resource
end
