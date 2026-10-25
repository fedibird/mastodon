# frozen_string_literal: true

# == Schema Information
#
# Table name: external_sources
#
#  id            :bigint(8)        not null, primary key
#  protocol      :string           not null
#  canonical_key :text             not null
#  etag          :text
#  last_modified :text
#  fetched_at    :datetime
#  checked_at    :datetime
#  title         :text
#  site_url      :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  icon_file_name     :string
#  icon_content_type  :string
#  icon_file_size     :bigint(8)
#  icon_updated_at    :datetime
#  icon_fingerprint   :string
#  icon_remote_url    :text
#  icon_origin        :string
#  icon_etag          :text
#  icon_last_modified :text
#  icon_hints         :jsonb
#  icon_checked_at    :datetime
#  icon_next_check_at :datetime
#  icon_failure_count :integer          default(0), not null
#  icon_error_code    :string
#
# The icon is one stored copy shared by every subscriber of the feed. Only the
# fetch job (ExternalBridge::RSS::Icon::RefreshSource) writes it. It is served
# through ExternalSourceIconsController, never from the original URL.
class ExternalSource < ApplicationRecord
  include Attachmentable

  PROTOCOLS = %w(rss atom).freeze
  ICON_MIME_TYPES = %w(image/png image/jpeg image/gif image/webp image/vnd.microsoft.icon image/x-icon).freeze
  ICON_UNPROCESSED_MIME_TYPES = %w(image/vnd.microsoft.icon image/x-icon).freeze
  ICON_SIZE = 128
  ICON_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -quality 90',
  }.freeze

  # Stored as a still 128px square WebP. A GIF keeps only its first frame, and
  # the geometry never upscales a smaller source. An ICO is stored as fetched:
  # it was already checked for type, size, and dimensions, and it never goes
  # through ImageMagick's ICO coder.
  has_attached_file :icon,
                    styles: ->(attachment) { icon_styles(attachment) },
                    convert_options: ICON_CONVERT_OPTIONS

  def self.icon_styles(attachment)
    return { original: { processors: [:pass_through] } } if ICON_UNPROCESSED_MIME_TYPES.include?(attachment.content_type)

    {
      original: {
        geometry: "#{ICON_SIZE}x#{ICON_SIZE}#",
        format: 'webp',
        content_type: 'image/webp',
        animated: false,
        file_geometry_parser: FastGeometryParser,
        processors: [:lazy_thumbnail, :type_corrector],
        source_file_options: '-limit time 10 -limit area 32MP',
      },
    }
  end
  private_class_method :icon_styles

  validates_attachment_content_type :icon, content_type: ICON_MIME_TYPES
  validates_attachment_size :icon, less_than: 1.megabyte

  has_many :external_resources, dependent: :restrict_with_exception
  has_many :external_subscriptions, dependent: :restrict_with_exception

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :canonical_key, presence: true
end
