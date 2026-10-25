# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # Download and vet one candidate image. The response is trusted only
      # after all of these agree: a 2xx status, an allowed Content-Type, bytes
      # that FastImage recognizes as an allowed raster format matching that
      # Content-Type, sane dimensions, and an icon-like shape. SVG is never
      # accepted. An ICO is stored unconverted, so it is also validated end to
      # end by IcoValidator. Nothing here writes to storage.
      class ImageFetch
        Result = Struct.new(:not_modified, :body, :type, :width, :height, :fingerprint, :content_type, :etag, :last_modified, :final_url, keyword_init: true)

        TYPES = {
          png: %w(image/png),
          jpeg: %w(image/jpeg),
          gif: %w(image/gif),
          webp: %w(image/webp),
          ico: %w(image/x-icon image/vnd.microsoft.icon image/ico),
        }.freeze

        EXTENSIONS = { png: 'png', jpeg: 'jpg', gif: 'gif', webp: 'webp', ico: 'ico' }.freeze

        def call(url, etag: nil, last_modified: nil)
          response = HttpClient.get(url, etag: etag, last_modified: last_modified, profile: HttpClient::ICON_IMAGE_PROFILE)
          return Result.new(not_modified: true, final_url: response.final_url) if response.code == 304

          raise Error, "http_#{response.code}" unless response.code.between?(200, 299)

          inspect_body!(response)
        end

        private

        def inspect_body!(response)
          raise Error, :icon_bad_content_type unless allowed_content_type?(response.content_type)

          body = response.body.to_s.b
          raise Error, :icon_empty if body.empty?

          type, width, height = identify!(body)
          raise Error, :icon_type_mismatch unless TYPES.fetch(type).include?(response.content_type)

          check_dimensions!(width, height)
          Result.new(
            not_modified: false,
            body: body,
            type: type,
            width: width,
            height: height,
            fingerprint: Digest::SHA256.hexdigest(body),
            content_type: response.content_type,
            etag: response.etag,
            last_modified: response.last_modified,
            final_url: response.final_url
          )
        end

        def allowed_content_type?(content_type)
          TYPES.values.flatten.include?(content_type)
        end

        def identify!(body)
          io = StringIO.new(body)
          type = FastImage.type(io)
          raise Error, :icon_unrecognized_image unless TYPES.key?(type)

          if type == :ico
            width, height = IcoValidator.validate!(body)
            return [type, width, height]
          end

          io.rewind
          width, height = FastImage.size(io)
          raise Error, :icon_unrecognized_image unless width.to_i.positive? && height.to_i.positive?

          [type, width.to_i, height.to_i]
        rescue FastImage::FastImageException, FastImage::UnknownImageType, FastImage::ImageFetchFailure, FastImage::SizeNotFound
          raise Error, :icon_unrecognized_image
        end

        def check_dimensions!(width, height)
          raise Error, :icon_dimensions if width > Limits::ICON_MAX_DIMENSION || height > Limits::ICON_MAX_DIMENSION
          raise Error, :icon_dimensions if width * height > Limits::ICON_MAX_PIXELS
          raise Error, :icon_too_small if [width, height].min < Limits::ICON_MIN_DIMENSION
          raise Error, :icon_unsuitable_shape if [width, height].max.to_f / [width, height].min > Limits::ICON_MAX_ASPECT
        end
      end
    end
  end
end
