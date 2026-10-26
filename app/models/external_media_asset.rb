# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_assets
#
#  id                 :bigint(8)        not null, primary key
#  url_digest         :string           not null
#  kind               :string           not null
#  state              :string           default("ready"), not null
#  content_type       :string
#  byte_size          :bigint(8)
#  fingerprint        :string
#  width              :integer
#  height             :integer
#  failure_code       :string
#  failed_revision    :string
#  attempt_count      :integer          default(0), not null
#  fetched_at         :datetime
#  file_file_name     :string
#  file_content_type  :string
#  file_file_size     :bigint(8)
#  file_updated_at    :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# One downloaded file shared by every subscriber of the same public URL.
# The URL itself is not stored. Callers pass its digest and keep the URL on
# the resource candidate list. This file is not a Status attachment.
#
# A ready asset is reused for every later candidate with the same normalized
# URL, even if the origin publishes new bytes at that URL. ETag and
# Last-Modified revalidation, repointing projection attachments at a
# replacement asset, and deleting the previous file are not implemented.
# That refresh and its garbage collection are P3.
#
# processing_failed means the shared bytes are stored but turning them into
# a MediaAttachment failed. The row stays out of the ready set until the
# backoff passes, so a refresh does not run ffmpeg again and the article
# keeps the remote player. Three failures for one media revision stop.
class ExternalMediaAsset < ApplicationRecord
  include Attachmentable

  KINDS = %w(image video).freeze
  STATES = %w(ready failed processing_failed).freeze
  IMAGE_MIME_TYPES = %w(image/jpeg image/png image/gif image/webp).freeze
  VIDEO_MIME_TYPES = %w(video/mp4 video/webm).freeze

  has_attached_file :file,
                    styles: ->(_) { { original: { processors: [:pass_through], animated: false } } }

  validates_attachment_content_type :file, content_type: IMAGE_MIME_TYPES + VIDEO_MIME_TYPES
  validates_attachment_size :file, less_than: MediaAttachment::VIDEO_LIMIT
  validates_attachment_presence :file, if: :ready?

  has_many :external_projection_attachments, dependent: :restrict_with_exception

  validates :url_digest, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }

  scope :ready, -> { where(state: 'ready') }

  def ready?
    state == 'ready'
  end

  def failed?
    state == 'failed'
  end

  def processing_failed?
    state == 'processing_failed'
  end

  # Same revision, inside the backoff or after the third failure. A newer
  # media revision is not blocked by the previous revision's counter.
  def processing_blocked?(revision)
    return false unless processing_failed?
    return false if failed_revision.present? && failed_revision.to_s != revision.to_s
    return true if attempt_count.to_i >= 3

    fetched_at.present? && fetched_at > self.class.processing_retry_delay(attempt_count).ago
  end

  def self.processing_retry_delay(attempt_count)
    step = [[attempt_count.to_i, 1].max, 6].min
    (15 * (2**(step - 1))).seconds
  end

  def exhausted_for?(revision)
    !ready? && failed_revision.to_s == revision.to_s && attempt_count.to_i >= 3
  end
end
