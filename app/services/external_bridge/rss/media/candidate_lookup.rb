# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Picks the candidate that may download or revalidate one logical digest.
      # A poster row wins when it covers that digest, because only that row
      # carries the signed fetch URL. An attachment of the same logical URL
      # does not widen the poster query rules to ordinary images.
      module CandidateLookup
        module_function

        def for_fetch(candidates, url_digest)
          prefer_poster(Array(candidates).select { |row| fetch_match?(row, url_digest) })
        end

        def for_revalidate(candidates, url_digest)
          prefer_poster(Array(candidates).select { |row| revalidate_match?(row, url_digest) })
        end

        def prefer_poster(rows)
          rows.find { |row| row['role'] == 'poster' } || rows.first
        end

        def fetch_match?(row, url_digest)
          %w(image video).include?(row['kind']) && MediaDigest.url_digest(row['url'].to_s) == url_digest
        end

        def revalidate_match?(row, url_digest)
          row['kind'] == 'image' && ImageAttempts.requests(row).any? { |item| MediaDigest.url_digest(item.store) == url_digest }
        end
      end
    end
  end
end
