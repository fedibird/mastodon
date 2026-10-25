# frozen_string_literal: true

# == Schema Information
#
# Table name: external_subscription_deletion_effects
#
#  id                                 :bigint(8)        not null, primary key
#  external_subscription_deletion_id  :bigint(8)        not null
#  status_id                          :bigint(8)        not null
#  destinations                       :jsonb
#  cache_cleared_at                   :datetime
#  search_cleared_at                  :datetime
#  stream_enqueued_at                 :datetime
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#
# One deleted projection status whose cache clear, search removal, or stream
# delete is not finished. destinations is null when no stream event is due
# (a personal projection). The row is removed only after every required step
# has been stamped. It holds ids, not feed text.
class ExternalSubscriptionDeletionEffect < ApplicationRecord
  belongs_to :external_subscription_deletion

  # Still missing cache, search, or a stream enqueue that is actually due.
  scope :outstanding, -> {
    where(<<~SQL.squish)
      cache_cleared_at IS NULL
      OR search_cleared_at IS NULL
      OR (destinations IS NOT NULL AND stream_enqueued_at IS NULL)
    SQL
  }
end
