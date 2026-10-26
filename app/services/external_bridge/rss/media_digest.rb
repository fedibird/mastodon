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
        Array(candidates).filter_map { |candidate| row(candidate) }
      end

      def hexdigest(candidates)
        Digest::SHA256.hexdigest(JSON.generate(normalize(candidates)))
      end

      def url_digest(url)
        Digest::SHA256.hexdigest(url.to_s)
      end

      def row(candidate)
        source = candidate.respond_to?(:to_h) ? candidate.to_h : {}
        source = source.stringify_keys
        FIELDS.each_with_object({}) do |key, memo|
          value = source[key]
          memo[key] = value unless value.nil?
        end
      end
    end
  end
end
