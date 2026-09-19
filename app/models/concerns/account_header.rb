# frozen_string_literal: true

module AccountHeader
  extend ActiveSupport::Concern

  # HEIC/HEIF/AVIF temporarily disabled (Mastodon 4.7.2 HEIF processing security).
  IMAGE_MIME_TYPES = %w(image/jpeg image/png image/gif image/webp image/bmp).freeze
  IMAGE_CONVERTIBLE_MIME_TYPES = %w(image/bmp).freeze
  LIMIT = 4.megabytes
  MAX_PIXELS = 750_000 # 1500x500px

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 90',
  }.freeze

  class_methods do
    def header_styles(file)
      styles = {
        original: {
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
          processors: [:lazy_thumbnail, :thumbhash_transcoder],
        },
      }

      if IMAGE_CONVERTIBLE_MIME_TYPES.include?(file.content_type)
        styles[:original].merge!({
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
        })
      end

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

    private :header_styles
  end

  included do
    # Header upload
    has_attached_file :header, styles: ->(f) { header_styles(f) }, convert_options: GLOBAL_CONVERT_OPTIONS
    validates_attachment_content_type :header, content_type: IMAGE_MIME_TYPES
    validates_attachment_size :header, less_than: LIMIT
    remotable_attachment :header, LIMIT, suppress_errors: false
  end

  def header_exists?
    remote_resource_exists?(full_asset_url(header.url(:original)))
  end

  def needs_header_redownload?
    header.blank? && header_remote_url.present?
  end

  def needs_header_reprocess?(version)
    !remote_resource_exists?(full_asset_url(header.url(version)))
  end

  def header_original_url
    header.url(:original)
  end

  def header_tiny_url
    header.url(:tiny)
  end

  def header_static_url
    header_content_type == 'image/gif' ? header.url(:static) : header_original_url
  end

  def header_tiny_static_url
    header_content_type == 'image/gif' ? header.url(:tiny_static) : header_tiny_url
  end
end
