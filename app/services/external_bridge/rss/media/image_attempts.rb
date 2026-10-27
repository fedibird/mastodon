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

        Request = Struct.new(:get, :store, keyword_init: true)

        def self.requests(candidate)
          rows = request_rows(candidate)
          rows.filter_map { |get, store| build_request(get, store) }.uniq(&:store).first(Limits::MAX_IMAGE_FETCH_ATTEMPTS)
        end

        def self.urls(candidate)
          requests(candidate).map(&:get)
        end

        # Separate from media_revision. The same representative with a
        # different fallback list hashes differently, so an exhausted primary
        # can be tried again. Unsafe URLs are already dropped by `urls`.
        def self.fingerprint(candidate)
          Digest::SHA256.hexdigest(JSON.generate(urls(candidate)))
        end

        # The representative chain may run when its row is missing, failed,
        # or alternate_selected. It does not run when that row is ready,
        # inside the processing backoff, or exhausted for this media revision
        # and this candidate fingerprint.
        #
        # Callers try a ready fallback first. alternate_selected therefore
        # means "do not GET while that fallback is ready", not "never GET".
        # Once every current fallback is gone or no longer ready, this opens
        # and the chain runs again. `rate_limited` never reaches here and
        # does not increment attempt_count. Three terminal failures of the
        # same fingerprint stop until the fallback list changes. Choosing an
        # alternate resets that budget to zero.
        def self.chain_open?(asset, revision, fingerprint)
          return true if asset.nil?
          return false if asset.ready? || asset.processing_blocked?(revision)

          !asset.exhausted_for?(revision, fingerprint)
        end

        def self.request_rows(candidate)
          if candidate['role'] == 'poster'
            rows = [[candidate['fetch_url'].presence || candidate['url'], candidate['url']]]
            Array(candidate['fallbacks']).each_with_index do |store, index|
              signed = Array(candidate['fetch_fallbacks'])[index]
              rows << [signed.presence || store, store]
            end
            return rows
          end

          [[candidate['url'], candidate['url']], *Array(candidate['fallbacks']).map { |store| [store, store] }]
        end

        def self.build_request(get, store)
          pair = PosterURL.pair(get)
          return nil if pair.nil? || svg?(pair.logical)
          return nil unless pair.logical == store.to_s

          Request.new(get: pair.fetch, store: pair.logical)
        end

        def self.safe(url)
          pair = PosterURL.pair(url)
          return nil if pair.nil? || pair.fetch != url.to_s
          return nil if svg?(pair.logical)

          pair.fetch
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
