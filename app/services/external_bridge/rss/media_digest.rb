# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Stable digest of article media candidates. Kept separate from the
    # title/body/url revision so a media-only edit is visible and a text-only
    # edit does not look like a media edit.
    module MediaDigest
      FIELDS = %w(url kind role origin mime_hint length_hint description position poster_url duration).freeze
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
          value = field_value(key, source[key])
          memo[key] = value unless value.nil?
        end
      end

      # `fallbacks` is stored for the fetch path and omitted from `row`, so a
      # change of alternates does not by itself change `media_revision`.
      # `usage` and `subject_url` are the same kind of hint: audio artwork
      # stays an attachment in this phase, and recording that label must not
      # by itself change media_revision.
      # `group` is the rendition list for one logical media. It is stored and
      # reloaded, and it is not part of `row`. A representative change is
      # already visible because url and kind are. A non-selected rendition
      # change updates the stored list without invalidating workers.
      HINTS = %w(audio_art author decoration).freeze

      def stored_row(candidate)
        source = source_hash(candidate)
        memo = row(source)
        return if memo.blank?

        fallbacks = fallback_urls(source['fallbacks'], memo['url'])
        memo['fallbacks'] = fallbacks if fallbacks.present?
        assign_poster_fetch!(memo, source)
        assign_usage!(memo, source)
        assign_group!(memo, source)
        memo
      end

      # Image fallbacks are not reused here. A group that fails the whitelist
      # is omitted and the representative candidate is kept.
      def assign_group!(memo, source)
        group = MediaGroup.sanitize_stored(source['group'])
        memo['group'] = group if group
      end

      def assign_usage!(memo, source)
        usage = source['usage'].to_s
        return unless HINTS.include?(usage)

        memo['usage'] = usage
        subject = source['subject_url'].to_s
        memo['subject_url'] = subject if usage == 'audio_art' && subject.present? && safe_fallback(subject, nil)
      end

      # The signed URL is how the bytes are fetched. It is not part of `row`,
      # so a new hash or expiry does not change media_revision.
      def assign_poster_fetch!(memo, source)
        return unless memo['kind'] == 'image' && memo['role'] == 'poster'

        merged = source.merge('url' => memo['url'], 'fallbacks' => Array(memo['fallbacks']), 'role' => 'poster')
        requests = Media::ImageAttempts.requests(merged)
        primary = requests.find { |item| item.store == memo['url'] }
        memo['fetch_url'] = primary.get if primary && primary.get != primary.store
        signed = Array(memo['fallbacks']).filter_map do |logical|
          found = requests.find { |item| item.store == logical }
          found.get if found && found.get != found.store
        end
        memo['fetch_fallbacks'] = signed if signed.present?
      end

      def field_value(key, value)
        return duration_value(value) if key == 'duration'

        value
      end

      def duration_value(value)
        return nil unless value.is_a?(Integer)
        return nil if value.negative? || value > Limits::MAX_MEDIA_DURATION

        value
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
        return nil if svg_url?(text)
        return text if MediaURL.normalize(text) == text

        pair = PosterURL.pair(text)
        return text if pair&.logical == text

        nil
      end

      def svg_url?(url)
        File.extname(Addressable::URI.parse(url).path.to_s).casecmp('.svg').zero?
      rescue Addressable::URI::InvalidURIError
        true
      end

      # One pass in candidate order. A group key gets 0, 1, 2… among copies
      # of that same key. A flat candidate has no ordinal, so its playback id
      # stays the file digest.
      def each_frame(candidates)
        counts = Hash.new(0)
        Array(candidates).each do |candidate|
          key = frame_group_key(candidate)
          ordinal = nil
          if key
            ordinal = counts[key]
            counts[key] += 1
          end
          yield candidate, ordinal
        end
      end

      # Physical file id is the URL digest. A group adds its key and the
      # copy number so two logical frames can share one file. `0` is a real
      # copy number. Flat candidates omit the suffix.
      def playback_id(url, group_key, ordinal)
        base = "rss-media:#{url_digest(url.to_s)[0, 16]}"
        return base if group_key.blank? || ordinal.nil?

        "#{base}:g:#{group_key.to_s[0, 12]}:#{ordinal}"
      end

      def frame_group_key(candidate)
        return nil unless candidate.is_a?(Hash)

        key = candidate.dig('group', 'key').to_s
        key if key.match?(/\A[0-9a-f]{64}\z/)
      end
    end
  end
end
