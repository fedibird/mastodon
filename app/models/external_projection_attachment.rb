# frozen_string_literal: true

# == Schema Information
#
# Table name: external_projection_attachments
#
#  id                            :bigint(8)        not null, primary key
#  external_status_projection_id :bigint(8)        not null
#  external_media_asset_id       :bigint(8)        not null
#  media_attachment_id           :bigint(8)        not null
#  position                      :integer          default(0), not null
#  kind                          :string           not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#
# The owner's MediaAttachment for one shared ExternalMediaAsset. Purging the
# projection removes this row in the same transaction that records an
# external_media_gc_intents plan. The attachment file and, when nothing else
# references it, the shared asset are released after that transaction
# commits. Another projection's reference keeps the shared asset.
class ExternalProjectionAttachment < ApplicationRecord
  KINDS = %w(image video).freeze

  belongs_to :external_status_projection
  belongs_to :external_media_asset
  belongs_to :media_attachment

  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
