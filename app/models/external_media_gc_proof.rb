# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_gc_proofs
#
#  id                            :bigint(8)        not null, primary key
#  source_attachment_id          :bigint(8)        not null
#  media_attachment_id           :bigint(8)        not null
#  external_status_projection_id :bigint(8)        not null
#  account_id                    :bigint(8)        not null
#  status_id                     :bigint(8)        not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#
# One projection-attachment link, copied while that link still existed.
# source_attachment_id is the external_projection_attachments id. The insert
# trigger overwrites the other ids from that live link. Updates of those
# columns are rejected. There is no foreign key: purge deletes the link and
# the projection, and this row is what still names the file.
class ExternalMediaGcProof < ApplicationRecord
  validates :source_attachment_id, :media_attachment_id, :external_status_projection_id, :account_id, :status_id, presence: true
end
