# frozen_string_literal: true

# Canonical upstream-compatible relation: an account follows a hashtag.
#
# Fedibird delivery destinations are intentionally stored separately in
# TagFollowDelivery. A TagFollow existing by itself MUST NOT imply Home
# delivery.
class TagFollow < ApplicationRecord
  include RateLimitable
  include Paginable

  belongs_to :tag
  belongs_to :account

  has_many :deliveries,
           class_name: 'TagFollowDelivery',
           inverse_of: :tag_follow,
           dependent: :destroy

  accepts_nested_attributes_for :tag

  rate_limit by: :account, family: :follows
end
