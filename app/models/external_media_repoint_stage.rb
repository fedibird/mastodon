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
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#
# Proof that one generation swap prepared this MediaAttachment. Release
# reads this row. It does not search attachments by description, type, or
# time. The projection and asset ids are nullable: purge and asset GC null
# them and leave the row. account_id and status_id stay, so a later pass
# can still recognize the file after the status itself is gone.
class ExternalMediaRepointStage < ApplicationRecord
  belongs_to :media_attachment
  belongs_to :external_media_asset, optional: true
  belongs_to :external_status_projection, optional: true

  validates :external_media_asset, :external_status_projection, presence: true, on: :create
  validates :lease_until, presence: true
end
