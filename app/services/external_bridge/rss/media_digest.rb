# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Stable digest of article media candidates. Kept separate from the
    # title/body/url revision so a media-only edit is visible and a text-only
    # edit does not look like a media edit.
    module MediaDigest
      FIELDS = %w(url kind role origin mime_hint length_hint description position poster_url).freeze
      EMPTY = Digest::SHA256.hexdigest('[]').freeze

      module_function

      def normalize(candidates)
        Array(candidates).filter_map { |candidate| stored_row(candidate) }
      end

      def hexdigest(candidates)
        Digest::SHA256.hexdigest(JSON.generate(Array(candidates).filter_map { |candidate| row(candidate) }))
      end

      def url_digest(url)
        Digest::SHA256.hexdigest(url.to_s)
      end

      def row(candidate)
        source = source_hash(candidate)
        FIELDS.each_with_object({}) do |key, memo|
          value = source[key]
          memo[key] = value unless value.nil?
        end
      end

      # `fallbacks` is stored for the fetch path and omitted from `row`, so a
      # change of alternates does not by itself change `media_revision`.
      def stored_row(candidate)
        source = source_hash(candidate)
        memo = row(source)
        return if memo.blank?

        fallbacks = fallback_urls(source['fallbacks'], memo['url'])
        memo['fallbacks'] = fallbacks if fallbacks.present?
        memo
      end

      def source_hash(candidate)
        source = candidate.respond_to?(:to_h) ? candidate.to_h : {}
        source.stringify_keys
      end

      def fallback_urls(values, primary)
        Array(values).filter_map { |url| safe_fallback(url, primary) }.uniq.first(Limits::MAX_IMAGE_FALLBACKS)
      end

      def safe_fallback(url, primary)
        text = url.to_s
        return nil if text.blank? || text == primary.to_s

        normalized = MediaURL.normalize(text)
        return nil unless normalized == text
        return nil if svg_url?(text)

        text
      end

      def svg_url?(url)
        File.extname(Addressable::URI.parse(url).path.to_s).casecmp('.svg').zero?
      rescue Addressable::URI::InvalidURIError
        true
      end
    end
  end
end
