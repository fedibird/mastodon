# frozen_string_literal: true

module AccountAvatar
  extend ActiveSupport::Concern

  # HEIC/HEIF/AVIF temporarily disabled (Mastodon 4.7.2 HEIF processing security).
  IMAGE_MIME_TYPES = %w(image/jpeg image/png image/gif image/webp image/bmp image/vnd.microsoft.icon).freeze
  IMAGE_CONVERTIBLE_MIME_TYPES = %w(image/bmp image/vnd.microsoft.icon).freeze
  IMAGE_ANIMATED_MIME_TYPES = %w(image/png image/gif image/webp).freeze
  LIMIT = 4.megabytes

  BLURHASH_OPTIONS = {
    x_comp: 4,
    y_comp: 4,
  }.freeze

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 90',
  }.freeze

  class_methods do
    def avatar_styles(file)
      styles = {
        original: {
          animated: true,
          geometry: '400x400#',
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail],
        },

        tiny: {
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
          geometry: '120x120#',
          file_geometry_parser: FastGeometryParser,
          processors: [:lazy_thumbnail, :blurhash_transcoder, :thumbhash_transcoder],
          blurhash: BLURHASH_OPTIONS,
        },
      }

      if IMAGE_CONVERTIBLE_MIME_TYPES.include?(file.content_type)
        styles[:original].merge!({
          format: 'webp',
          content_type: 'image/webp',
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
          geometry: '120x120#',
        })
      end

      styles
    end

    private :avatar_styles
  end

  included do
    # Avatar upload
    has_attached_file :avatar, styles: ->(f) { avatar_styles(f) }, convert_options: GLOBAL_CONVERT_OPTIONS
    validates_attachment_content_type :avatar, content_type: IMAGE_MIME_TYPES
    validates_attachment_size :avatar, less_than: LIMIT
    remotable_attachment :avatar, LIMIT, suppress_errors: false
  end

  def avatar_exists?
    remote_resource_exists?(full_asset_url(avatar.url(:original)))
  end

  def needs_avatar_redownload?
    avatar.blank? && avatar_remote_url.present?
  end

  def needs_avatar_reprocess?(version)
    !remote_resource_exists?(full_asset_url(avatar.url(version)))
  end

  def avatar_original_url
    avatar.url(:original)
  end

  def avatar_tiny_url
    avatar.url(:tiny)
  end

  def avatar_static_url
    avatar_content_type == 'image/gif' ? avatar.url(:static) : avatar_original_url
  end

  def avatar_tiny_static_url
    avatar_content_type == 'image/gif' ? avatar.url(:tiny_static) : avatar_tiny_url
  end
end
