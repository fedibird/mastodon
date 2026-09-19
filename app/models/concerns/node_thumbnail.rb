# frozen_string_literal: true

module NodeThumbnail
  extend ActiveSupport::Concern

  # HEIC/HEIF/AVIF temporarily disabled (Mastodon 4.7.2 HEIF processing security).
  IMAGE_MIME_TYPES = %w(image/jpeg image/png image/gif image/webp image/bmp).freeze
  LIMIT = 4.megabytes

  MAX_PIXELS = 750_000 # 1500x500px

  BLURHASH_OPTIONS = {
    x_comp: 4,
    y_comp: 4,
  }.freeze

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 90',
  }.freeze

  class_methods do
    def thumbnail_styles(file)
      styles = {
        original: {
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
          pixels: MAX_PIXELS,
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail],
        },

        tiny: {
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
          pixels: 40_000, # 200x200px
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail, :blurhash_transcoder, :thumbhash_transcoder],
          blurhash: BLURHASH_OPTIONS,
        },
      }

      if file.content_type == 'image/gif'
        styles[:tiny].merge!({
          format: 'gif',
          content_type: 'image/gif',
        })

        styles[:static] = {
          format: 'webp',
          content_type: 'image/webp',
          animated: false,
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail],
        }

        styles[:tiny_static] = styles[:static].merge({
          pixels: 40_000, # 200x200px
        })
      end

      styles
    end

    private :thumbnail_styles
  end

  included do
    # Thumbnail upload
    has_attached_file :thumbnail, styles: ->(f) { thumbnail_styles(f) }, convert_options: GLOBAL_CONVERT_OPTIONS

    validates_attachment_content_type :thumbnail, content_type: IMAGE_MIME_TYPES
    validates_attachment_size :thumbnail, less_than: LIMIT
    remotable_attachment :thumbnail, LIMIT, suppress_errors: false
  end

  def thumbnail_original_url
    thumbnail.url(:original)
  end

  def thumbnail_tiny_url
    thumbnail.url(:tiny)
  end

  def thumbnail_static_url
    thumbnail_content_type == 'image/gif' ? thumbnail.url(:static) : thumbnail_original_url
  end

  def thumbnail_tiny_static_url
    thumbnail_content_type == 'image/gif' ? thumbnail.url(:tiny_static) : thumbnail_tiny_url
  end
end
