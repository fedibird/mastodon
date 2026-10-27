# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_repoint_stages
#
#  id                              :bigint(8)        not null, primary key
#  media_attachment_id             :bigint(8)        not null
#  external_media_asset_id         :bigint(8)        not null
#  external_status_projection_id   :bigint(8)        not null
#  account_id                      :bigint(8)        not null
#  status_id                       :bigint(8)        not null
#  lease_until                     :datetime         not null
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#
# Proof that one generation swap prepared this MediaAttachment for one
# projection. Release reads this row. It does not search attachments by
# description, type, or time. The lease stays in the future while the
# worker is copying. A later pass may delete the file only after the lease
# has lapsed, the projection link is absent, and the account and status
# still match.
class ExternalMediaRepointStage < ApplicationRecord
  belongs_to :media_attachment
  belongs_to :external_media_asset
  belongs_to :external_status_projection

  validates :lease_until, presence: true
end
