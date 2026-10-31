# frozen_string_literal: true

module GroupCreationIcons
  # Response headers for an authenticated preview. The filename is derived
  # from the detected type, never from the upload name.
  module Delivery
    EXTENSIONS = {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'image/bmp' => '.bmp',
      'image/vnd.microsoft.icon' => '.ico',
    }.freeze

    module_function

    def allowed_mime?(mime)
      EXTENSIONS.key?(mime)
    end

    def extension(mime)
      EXTENSIONS.fetch(mime)
    end

    def filename(mime)
      "icon#{extension(mime)}"
    end

    def headers(mime)
      {
        'Cache-Control' => 'private, no-store',
        'X-Content-Type-Options' => 'nosniff',
        'Content-Security-Policy' => "default-src 'none'; sandbox",
        'Content-Disposition' => "inline; filename=\"#{filename(mime)}\"",
      }
    end
  end
end
