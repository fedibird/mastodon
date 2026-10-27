# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_gc_asset_rechecks
#
#  id                                 :bigint(8)        not null, primary key
#  external_media_asset_id            :bigint(8)        not null
#  reason                             :string(32)       not null
#  state                              :string(16)       default("pending"), not null
#  external_subscription_deletion_id  :bigint(8)
#  available_at                       :datetime         not null
#  last_error_code                    :string(64)
#  resolved_at                        :datetime
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#
# A reference to a shared asset was dropped. Several of these can exist for
# one asset at once. The pending-intent unique index can swallow a second
# plan; this row cannot, and it commits in the same transaction as the
# projection delete. Settlement after that commit inserts a new pending
# intent when nothing still points at the asset.
class ExternalMediaGcAssetRecheck < ApplicationRecord
  REASONS = %w(projection_purge asset_unreferenced generation_replaced).freeze
  STATES = %w(pending done).freeze

  validates :reason, inclusion: { in: REASONS }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: 'pending') }
  scope :due, -> { pending.where('available_at <= ?', Time.current) }
end
