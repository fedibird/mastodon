# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # URLs for one logical image, in the order MediaHtml ranked them.
      # Unsafe URLs are dropped before any request. A 404, a timeout, a MIME
      # mismatch, and an SSRF rejection are different codes. Only the SSRF
      # rejection and the other per-URL failures move on, and `rate_limited`
      # stops the chain so a loop cannot spend the host budget.
      class ImageAttempts
        NEXT_CODES = %w(
          media_bad_content_type media_type_mismatch media_unrecognized_image
          media_empty media_too_large media_dimensions unsupported_url
          private_address authenticated_source_rejected fetch_failed
          too_many_redirects http_304
        ).freeze

        def self.urls(candidate)
          raw = [candidate['url'], *Array(candidate['fallbacks'])]
          raw.filter_map { |url| safe(url) }.uniq.first(Limits::MAX_IMAGE_FETCH_ATTEMPTS)
        end

        def self.safe(url)
          text = url.to_s
          return nil if text.blank?

          normalized = MediaURL.normalize(text)
          return nil unless normalized == text
          return nil if svg?(text)

          text
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def self.try_next?(code)
          text = code.to_s
          return true if text.start_with?('http_')

          NEXT_CODES.include?(text)
        end

        def self.stop?(code)
          code.to_s == 'rate_limited'
        end

        def self.svg?(url)
          File.extname(Addressable::URI.parse(url).path.to_s).casecmp('.svg').zero?
        end
      end
    end
  end
end
