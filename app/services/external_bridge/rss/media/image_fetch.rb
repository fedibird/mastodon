# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Download one article image. The bytes are trusted only when the
      # Content-Type, the sniffed type, and the size all agree. SVG is never
      # accepted. Nothing here writes to storage.
      class ImageFetch
        Result = Struct.new(
          :body, :type, :content_type, :width, :height, :fingerprint,
          :etag, :last_modified, :not_modified,
          keyword_init: true
        )
        TYPES = {
          png: 'image/png',
          jpeg: 'image/jpeg',
          gif: 'image/gif',
          webp: 'image/webp',
        }.freeze

        def call(url, etag: nil, last_modified: nil)
          response = HttpClient.get(url, etag: etag, last_modified: last_modified, profile: HttpClient::MEDIA_IMAGE_PROFILE)
          return Result.new(not_modified: true) if response.code == 304
          raise Error, "http_#{response.code}" unless response.code.between?(200, 299)

          inspect_body!(response)
        end

        private

        def inspect_body!(response)
          type = TYPES.key(response.content_type)
          raise Error, :media_bad_content_type if type.nil?

          body = response.body.to_s.b
          raise Error, :media_empty if body.empty?
          raise Error, :media_too_large if body.bytesize > Limits::MEDIA_IMAGE_MAX_BYTES

          width, height = measure!(body, type)
          Result.new(
            body: body,
            type: type,
            content_type: response.content_type,
            width: width,
            height: height,
            fingerprint: Digest::SHA256.hexdigest(body),
            etag: response.etag,
            last_modified: response.last_modified,
            not_modified: false
          )
        end

        def measure!(body, type)
          io = StringIO.new(body)
          sniffed = FastImage.type(io)
          raise Error, :media_type_mismatch unless sniffed == type

          io.rewind
          width, height = FastImage.size(io)
          raise Error, :media_unrecognized_image unless width.to_i.positive? && height.to_i.positive?
          raise Error, :media_dimensions if width > Limits::MEDIA_IMAGE_MAX_DIMENSION || height > Limits::MEDIA_IMAGE_MAX_DIMENSION
          raise Error, :media_dimensions if width * height > Limits::MEDIA_IMAGE_MAX_PIXELS

          [width.to_i, height.to_i]
        rescue FastImage::FastImageException, FastImage::UnknownImageType, FastImage::ImageFetchFailure, FastImage::SizeNotFound
          raise Error, :media_unrecognized_image
        end
      end
    end
  end
end
