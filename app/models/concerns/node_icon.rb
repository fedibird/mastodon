# frozen_string_literal: true

module NodeIcon
  extend ActiveSupport::Concern

  # HEIC/HEIF/AVIF temporarily disabled (Mastodon 4.7.2 HEIF processing security).
  IMAGE_MIME_TYPES = %w(image/jpeg image/png image/gif image/webp image/vnd.microsoft.icon).freeze
  IMAGE_CONVERTIBLE_MIME_TYPES = %w(image/vnd.microsoft.icon).freeze
  LIMIT = 4.megabytes

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 90',
  }.freeze

  class_methods do
    def icon_styles(file)
      styles = {
        original: {
          animated: true,
          geometry: '400x400#',
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail],
        }
      }

      if IMAGE_CONVERTIBLE_MIME_TYPES.include?(file.content_type)
        styles[:original].merge!({
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
        })
      end

      if file.content_type == 'image/gif'
        styles[:static] = {
          format: 'webp',
          content_type: 'image/webp',
          animated: false,
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail],
        }
      end

      styles
    end

    private :icon_styles
  end

  included do
    # Icon upload
    has_attached_file :icon, styles: ->(f) { icon_styles(f) }, convert_options: GLOBAL_CONVERT_OPTIONS
    validates_attachment_content_type :icon, content_type: IMAGE_MIME_TYPES, presence: true
    validates_attachment_size :icon, less_than: LIMIT
    remotable_attachment :icon, LIMIT, suppress_errors: true
  end

  def icon_original_url
    icon.url(:original)
  end

  def icon_static_url
    icon_content_type == 'image/gif' ? icon.url(:static) : icon_original_url
  end
end
