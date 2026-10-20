# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Status text has to pass StatusLengthValidator. The shared resource
    # keeps the full public body; the projection stores only this excerpt.
    class Excerpt
      MAX_CHARS = StatusLengthValidator::MAX_CHARS

      def self.for(resource)
        new(resource).to_s
      end

      def initialize(resource)
        @resource = resource
      end

      def to_s
        title = @resource.title.to_s.strip
        byline = @resource.byline.to_s.strip
        url = @resource.canonical_url.to_s.strip
        body = plain_body(@resource.body)
        fitted = shrink(title, byline, url, body)
        return fitted if fitted.present? && fits?(fitted)

        fallback
      end

      private

      def plain_body(body)
        body.to_s.gsub(%r{https?://[^\s<>]+}i, ' ').squish
      end

      def shrink(title, byline, url, body)
        full = join([title, byline, url])
        return longest_with_body(full, body) if full.present? && fits?(full)

        if url.present? && fits?(url)
          return longest_with_body(head_with_optional(title, byline, url), body)
        end

        plain = truncate_graphemes(title.presence || I18n.t('external_bridge.untitled'), MAX_CHARS)
        return longest_with_body(plain, body) if fits?(plain)

        nil
      end

      def head_with_optional(title, byline, url)
        with_byline = fit_prefix([title, byline], url)
        return with_byline if with_byline.present? && fits?(with_byline)

        fit_prefix([title], url)
      end

      def fit_prefix(parts, required)
        clusters = join(parts).each_grapheme_cluster.to_a
        best = required
        low = 0
        high = [clusters.size, MAX_CHARS].min
        while low <= high
          mid = (low + high) / 2
          candidate = join([clusters.take(mid).join, required])
          if fits?(candidate)
            best = candidate
            low = mid + 1
          else
            high = mid - 1
          end
        end
        best
      end

      def longest_with_body(head, body)
        # Only the first MAX_CHARS graphemes can fit beside the head.
        clusters = body.to_s.each_grapheme_cluster.take(MAX_CHARS + 1).to_a
        return head if clusters.empty?

        best = head
        low = 0
        high = clusters.size
        while low <= high
          mid = (low + high) / 2
          candidate = join([head, clusters.take(mid).join])
          if fits?(candidate)
            best = candidate
            low = mid + 1
          else
            high = mid - 1
          end
        end
        best
      end

      def join(parts)
        Array(parts).flatten.map { |part| part.to_s.strip }.reject(&:blank?).join("\n\n")
      end

      def truncate_graphemes(text, max)
        text.to_s.each_grapheme_cluster.take(max).join
      end

      def fits?(text)
        return false if text.blank?

        status = Status.new(text: text, local: true, spoiler_text: '')
        StatusLengthValidator.new({}).validate(status)
        status.errors[:text].blank?
      end

      def fallback
        untitled = I18n.t('external_bridge.untitled')
        return untitled if fits?(untitled)

        truncate_graphemes(untitled, MAX_CHARS)
      end
    end
  end
end
