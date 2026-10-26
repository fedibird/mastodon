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
        add_url(preferred_picture(node, img), 'image', 'html_picture', img || node)
      end

      def preferred_picture(node, img)
        sources = node.css('source').filter_map { |source| picture_source(source) }
        best = sources.select { |row| row[:webp] }.max_by { |row| row[:width] }
        best ||= sources.max_by { |row| row[:width] }
        return best[:url] if best

        img&.[]('src').presence || first_url(img&.[]('srcset'))
      end

      def picture_source(source)
        url = first_url(source['srcset'].presence || source['src'])
        return if url.blank?

        { url: url, width: source['srcset'].to_s[/\s(\d+)w/, 1].to_i, webp: webp?(source, url) }
      end

      def webp?(source, url)
        source['type'].to_s.include?('webp') || url.match?(/\.webp(\z|\?)/i)
      end

      def add_image(node)
        return if tracking_pixel?(node)

        add_url(node['src'].presence || first_url(node['srcset']), 'image', 'html_img', node)
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

        @raw << {
          'url' => absolute,
          'kind' => kind,
          'role' => 'attachment',
          'origin' => origin,
          'description' => description(node),
          'poster_url' => poster.present? && kind == 'video' ? resolve(poster) : nil,
        }.compact
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

      def first_url(srcset)
        srcset.to_s.split(',').first.to_s.strip.split(/\s+/).first
      end

      def tracking_pixel?(node)
        width = node['width'].to_s
        height = node['height'].to_s
        width.match?(/\A[01]\z/) && height.match?(/\A[01]\z/)
      end
    end
  end
end
