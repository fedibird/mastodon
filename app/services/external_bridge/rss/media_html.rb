# frozen_string_literal: true

module ExternalBridge
  module RSS
    # HTML embedded in a feed body. The fragment is never serialized back into
    # a page and script, iframe, and embed nodes are dropped before attributes
    # are read. YouTube-style players are out of scope.
    class MediaHtml
      def self.extract(html, base, raw, posters)
        new(html, base, raw, posters).extract
      end

      def initialize(html, base, raw, posters)
        @html = html.to_s
        @base = base
        @raw = raw
        @posters = posters
      end

      def extract
        return if @html.blank?

        fragment = Nokogiri::HTML.fragment(@html)
        fragment.css('script,style,iframe,object,embed,link,meta,noscript').remove
        fragment.css('picture, img, video, audio').each { |node| add_node(node) }
      rescue StandardError => e
        Rails.logger.info("[ExternalBridge::RSS] media html skipped error=#{e.class}")
        nil
      end

      private

      def add_node(node)
        return if node.name == 'img' && node.ancestors.any? { |ancestor| ancestor.name == 'picture' }

        case node.name
        when 'picture' then add_picture(node)
        when 'img' then add_image(node)
        when 'video' then add_video(node)
        when 'audio' then add_audio(node)
        end
      end

      def add_picture(node)
        img = node.at_css('img')
        add_image_choice(ranked_picture(node, img), 'html_picture', img || node)
      end

      # One logical image. `media` on `<source>` is not evaluated: this server
      # does not know the reader's viewport, so a min-width source is eligible
      # whenever its declared width wins. `w` outranks `x`. Equal widths prefer
      # WebP (`type` or a .webp URL) and then the higher density. The first
      # ranked URL stays the representative, which keeps media_revision stable.
      # The rest are `fallbacks`, in that same order, and are not digested.
      def ranked_picture(node, img)
        rows = node.css('source').flat_map { |source| declared_rows(source) }
        rows.concat(declared_rows(img))
        rank(rows)
      end

      def declared_rows(node)
        return [] if node.nil?

        # `src` is one URL. Only `srcset` is split on commas, so a data URL's
        # comma is not treated as a second candidate.
        rows = srcset_candidates(node['srcset']).map { |row| row.merge(webp: webp?(node, row[:url])) }
        extra = node['src']
        return rows if extra.blank? || rows.any? { |row| row[:url] == extra }

        rows << { url: extra, width: 0, density: 1.0, webp: webp?(node, extra) }
      end

      def webp?(source, url)
        source['type'].to_s.include?('webp') || url.match?(/\.webp(\z|\?)/i)
      end

      def add_image(node)
        return if tracking_pixel?(node)

        add_image_choice(ranked_image(node), 'html_img', node)
      end

      # An `<img>` with only `x` descriptors keeps `src` as the representative.
      # A positive `w` still replaces `src`. That matches the previous choice.
      def ranked_image(node)
        rows = declared_rows(node)
        return rank(rows) if rows.any? { |row| row[:width].positive? }

        src = rows.find { |row| row[:url] == node['src'] }
        others = rows.reject { |row| row.equal?(src) }
        [src, *rank(others)].compact
      end

      def add_image_choice(ranked, origin, node)
        resolved = resolve_rows(ranked)
        return if resolved.blank?

        @pending_fallbacks = resolved.drop(1).map { |row| row[:url] }.uniq.first(Limits::MAX_IMAGE_FALLBACKS)
        add_url(resolved.first[:url], 'image', origin, node)
      ensure
        @pending_fallbacks = nil
      end

      def resolve_rows(rows)
        resolved = Array(rows).filter_map do |row|
          absolute = resolve(row[:url])
          next if absolute.blank? || svg?(absolute)

          row.merge(url: absolute)
        end
        resolved.uniq { |row| row[:url] }
      end

      def rank(rows)
        Array(rows).sort_by { |row| [-row[:width].to_i, row[:webp] ? 0 : 1, -row[:density].to_f] }
      end

      def srcset_candidates(srcset)
        srcset.to_s.split(',').filter_map do |part|
          bits = part.strip.split(/\s+/)
          url = bits.shift
          next if url.blank?

          width = 0
          density = 1.0
          bits.each do |descriptor|
            width = descriptor.to_i if descriptor.end_with?('w')
            density = descriptor.to_f if descriptor.end_with?('x')
          end
          { url: url, width: width, density: density }
        end
      end

      def add_video(node)
        add_url(preferred_typed(node, %w(mp4 webm)), 'video', 'html_video', node, poster: node['poster'])
        remember(node['poster'])
      end

      def add_audio(node)
        add_url(preferred_typed(node, %w(mpeg mp3)), 'audio', 'html_audio', node)
      end

      # One file for the element. A picture's sources, or a video's mp4 and
      # webm, are variants of the same media rather than extra attachments.
      def preferred_typed(node, preferences)
        choices = []
        choices << ['', node['src']] if node['src'].present?
        node.css('source').each { |source| choices << [source['type'].to_s.downcase, source['src']] }
        preferences.each do |name|
          found = choices.find { |type, src| src.present? && (type.include?(name) || src.include?(".#{name}")) }
          return found.last if found
        end
        choices.find { |_type, src| src.present? }&.last
      end

      def add_url(value, kind, origin, node, poster: nil)
        absolute = resolve(value)
        return if absolute.blank? || svg?(absolute)

        payload = {
          'url' => absolute,
          'kind' => kind,
          'role' => 'attachment',
          'origin' => origin,
          'description' => description(node),
          'poster_url' => poster.present? && kind == 'video' ? resolve(poster) : nil,
        }.compact
        fallbacks = Array(@pending_fallbacks).reject { |url| url == absolute }.uniq.first(Limits::MAX_IMAGE_FALLBACKS)
        payload['fallbacks'] = fallbacks if fallbacks.present?
        @raw << payload
        remember(poster) if kind == 'video'
      end

      def svg?(url)
        File.extname(Addressable::URI.parse(url).path.to_s).casecmp('.svg').zero?
      rescue Addressable::URI::InvalidURIError
        false
      end

      def resolve(value)
        text = value.to_s.strip
        return nil if text.blank?
        return nil if text.match?(/\A[a-z][a-z0-9+.-]*:/i) && !text.match?(/\Ahttps?:/i)

        joined = text.match?(/\Ahttps?:/i) ? text : join(text)
        MediaURL.normalize(joined)
      end

      def join(text)
        return nil if @base.blank?

        Addressable::URI.join(@base, text).to_s
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def remember(value)
        absolute = resolve(value)
        @posters << absolute if absolute.present?
      end

      def description(node)
        alt = node['alt'].presence
        caption = node.ancestors.find { |ancestor| ancestor.name == 'figure' }&.at_css('figcaption')&.text
        text = Sanitizer.plain(alt || caption).gsub(/\s+/, ' ').strip
        return nil if text.blank?

        text.slice(0, Limits::MAX_MEDIA_DESCRIPTION)
      end

      def tracking_pixel?(node)
        width = node['width'].to_s
        height = node['height'].to_s
        width.match?(/\A[01]\z/) && height.match?(/\A[01]\z/)
      end
    end
  end
end
