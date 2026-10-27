# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_repoint_stages
#
#  id                              :bigint(8)        not null, primary key
#  media_attachment_id             :bigint(8)        not null
#  external_media_asset_id         :bigint(8)
#  external_status_projection_id   :bigint(8)
#  account_id                      :bigint(8)        not null
#  status_id                       :bigint(8)        not null
#  lease_until                     :datetime         not null
#  state                           :string           default("pending"), not null
#  available_at                    :datetime         not null
#  attempt_count                   :integer          default(0), not null
#  failure_code                    :string
#  claim_token                     :string
#  claimed_until                   :datetime
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#
# Proof that one generation swap prepared this MediaAttachment. Release
# reads this row. It does not search attachments by description, type, or
# time. The projection and asset ids are nullable: purge and asset GC null
# them and leave the row. account_id and status_id stay, so a later pass
# can still recognize the file after the status itself is gone.
# available_at hides a row that failed until its backoff elapses. retained
# keeps the proof and leaves the sweep.
class ExternalMediaRepointStage < ApplicationRecord
  belongs_to :media_attachment
  belongs_to :external_media_asset, optional: true
  belongs_to :external_status_projection, optional: true

  validates :external_media_asset, :external_status_projection, presence: true, on: :create
  validates :lease_until, :available_at, presence: true
  validates :state, inclusion: { in: %w(pending retained) }

  before_validation :schedule_with_lease, on: :create

  private

  def schedule_with_lease
    self.state = 'pending' if state.blank?
    self.available_at ||= lease_until
  end
end
