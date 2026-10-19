# frozen_string_literal: true

# == Schema Information
#
# Table name: external_resources
#
#  id                 :bigint(8)        not null, primary key
#  external_source_id :bigint(8)        not null
#  external_actor_id  :bigint(8)
#  protocol           :string           not null
#  canonical_key      :text             not null
#  revision           :text
#  canonical_url      :text
#  title              :text
#  body               :text
#  byline             :text
#  body_digest        :string
#  published_at       :datetime
#  source_deleted_at  :datetime
#  truncated          :boolean          default(FALSE), not null
#  fetched_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class ExternalResource < ApplicationRecord
  PROTOCOLS = %w(rss atom).freeze

  belongs_to :external_source
  belongs_to :external_actor, optional: true
  has_many :external_status_projections, dependent: :restrict_with_exception

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :canonical_key, presence: true
end
