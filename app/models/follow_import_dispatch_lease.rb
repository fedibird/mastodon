# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_dispatch_leases
#
#  id                  :bigint(8)        not null, primary key
#  owner_token         :string
#  fencing_generation  :bigint(8)        not null
#  expires_at          :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Singleton durable ownership row for the Follow Import dispatcher.
# Session advisory locks are not used; expiry is compared with PostgreSQL
# clock_timestamp(), not the application host clock.
class FollowImportDispatchLease < ApplicationRecord
  self.table_name = 'follow_import_dispatch_leases'

  SINGLETON_ID = 1

  def self.singleton
    find_by(id: SINGLETON_ID)
  end

  def held_at?(now)
    owner_token.present? && expires_at.present? && expires_at > now
  end
end
