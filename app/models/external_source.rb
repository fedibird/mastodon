# frozen_string_literal: true

# == Schema Information
#
# Table name: external_sources
#
#  id            :bigint(8)        not null, primary key
#  protocol      :string           not null
#  canonical_key :text             not null
#  etag          :text
#  last_modified :text
#  fetched_at    :datetime
#  checked_at    :datetime
#  title         :text
#  site_url      :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class ExternalSource < ApplicationRecord
  PROTOCOLS = %w(rss atom).freeze

  has_many :external_resources, dependent: :restrict_with_exception
  has_many :external_subscriptions, dependent: :restrict_with_exception

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :canonical_key, presence: true
end
