# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_gc_intents
#
#  id                                 :bigint(8)        not null, primary key
#  target_type                        :string(32)       not null
#  target_id                          :bigint(8)        not null
#  reason                             :string(32)       not null
#  state                              :string(16)       default("pending"), not null
#  owner_account_id                   :bigint(8)
#  captured_status_id                 :bigint(8)
#  source_attachment_id               :bigint(8)
#  captured_projection_id             :bigint(8)
#  external_subscription_deletion_id  :bigint(8)
#  available_at                       :datetime         not null
#  attempt_count                      :integer          default(0), not null
#  last_error_code                    :string(64)
#  lease_token                        :string(32)
#  leased_until                       :datetime
#  resolved_at                        :datetime
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#
# One file this process promised to release after a projection purge or a
# shared-asset replacement. For a MediaAttachment, source_attachment_id is
# the external_projection_attachments id and captured_projection_id is the
# projection that owned that link. ExternalMediaGcProof is the copy of that
# link taken while it still existed. Recovery must not infer eligibility
# from media_attachments.status_id being null: compose uploads look the same
# after a purge nullifies that column.
#
# external_subscription_deletion_id is a correlation id only. It is not a
# foreign key, so retention cleanup of a finished unsubscribe cannot delete
# the plan or block on it. The row stores no URL, token, or file name.
class ExternalMediaGcIntent < ApplicationRecord
  TARGET_TYPES = %w(media_attachment external_media_asset).freeze
  REASONS = %w(projection_purge attachment_replaced asset_unreferenced generation_replaced).freeze
  STATES = %w(pending released retained failed).freeze

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :reason, inclusion: { in: REASONS }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: 'pending') }
  scope :due, -> { pending.where('available_at <= ?', Time.current) }

  def pending?
    state == 'pending'
  end
end
