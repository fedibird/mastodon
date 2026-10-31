# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Item-level player, poster, duration, and keywords. HTML is read only
    # to copy an iframe src. The fragment is not saved and not rendered.
    class EmbedScan
      LARGE = %w(thumb_large thumbnail_large).freeze
      SMALL = %w(thumb thumbnail).freeze
      Result = Struct.new(:keywords, keyword_init: true)

      def self.new_scan
        new
      end

      def initialize
        @players = []
        @large = []
        @small = []
        @poster_at = nil
        @duration = nil
        @keywords = nil
        @html_at = nil
      end

      def observe(child, at)
        observe_facts(child)
        remember_thumb(child, at)
        remember_embed(child, at)
        remember_player(child, at)
      end

      # Duration and keywords inside a media:group still count. Players and
      # embeds in that group belong to the group, so they are not collected
      # here.
      def observe_facts(child)
        @duration ||= duration_from(child)
        @keywords ||= keywords_from(child)
      end

      def note_html_at(at)
        @html_at = at
      end

      def finish_html(html)
        urls = iframe_urls(html)
        return if urls.empty?

        @players << { priority: 3, at: @html_at || 0, origin: 'html_iframe', urls: urls }
      end

      def keywords
        Keywords.normalize(@keywords)
      end

      # A thumb is the player's poster. Without an accepted player there is
      # nothing to show it on, so the image is not stored or fetched.
      def apply!(raw, posters, article_url)
        poster = poster_row
        player = player_row(article_url, poster)
        return if player.nil?

        if poster
          poster[:hide].each { |url| posters << url if url.present? }
        end
        rows = []
        rows << { at: @poster_at || raw.size, candidate: poster[:candidate] } if poster
        rows << { at: player[:at], candidate: player[:candidate] }
        shift = 0
        rows.sort_by { |row| row[:at].to_i }.each do |row|
          raw.insert([row[:at].to_i + shift, raw.size].min, row[:candidate])
          shift += 1
        end
      end

      private

      def duration_from(child)
        return nil unless child.name == 'duration'
        return nil unless duration_namespace?(child)

        text = child.text.to_s.strip
        return nil unless text.match?(/\A\d{1,7}\z/)

        number = Integer(text, 10)
        return nil if number.negative? || number > Limits::MAX_MEDIA_DURATION

        number
      rescue ArgumentError
        nil
      end

      def keywords_from(child)
        return nil unless child.name == 'keywords'
        return nil unless keyword_namespace?(child)

        child.text
      end

      def duration_namespace?(child)
        href = child.namespace&.href
        href.nil? || href == MediaExtractor::ITUNES
      end

      def keyword_namespace?(child)
        href = child.namespace&.href
        href.nil? || href == MediaExtractor::ITUNES || href == MediaExtractor::MEDIA
      end

      def remember_thumb(child, at)
        bucket = thumb_bucket(child)
        return if bucket.nil?

        pair = PosterURL.pair(child.text)
        return if pair.nil?

        (bucket == :large ? @large : @small) << pair
        @poster_at = at if @poster_at.nil?
      end

      def thumb_bucket(child)
        return nil if child.namespace&.href == MediaExtractor::MEDIA

        return :large if LARGE.include?(child.name)
        return :small if SMALL.include?(child.name)

        nil
      end

      # media:embed contributes its url attribute only. An embed with no
      # namespace still contributes iframe src values. media:param and the
      # element's text are not player markup.
      def remember_embed(child, at)
        return unless child.name == 'embed'

        href = child.namespace&.href
        return if href == MediaExtractor::ATOM
        if href == MediaExtractor::MEDIA
          remember_media_embed(child, at)
          return
        end
        # RSS 1.0 puts the default namespace on embed. That is still the
        # iframe path. A foreign namespace is not.
        return if href && href != XmlNames::RSS1

        urls = embed_urls(child)
        return if urls.empty?

        @players << { priority: 1, at: at, origin: 'rss_embed', urls: urls }
      end

      def remember_media_embed(child, at)
        attribute = child.attribute_with_ns('url', nil)
        return if attribute.nil?

        url = attribute.value.to_s.strip
        return if url.blank?

        @players << { priority: 1, at: at, origin: 'media_embed', urls: [url] }
      end

      def remember_player(child, at)
        urls = player_urls(child)
        return if urls.empty?

        @players << { priority: 2, at: at, origin: 'media_player', urls: urls }
      end

      def player_urls(child)
        return [] unless child.name == 'player' && child.namespace&.href == MediaExtractor::MEDIA

        [child.attribute_with_ns('url', nil)&.value.to_s].reject(&:blank?)
      end

      def embed_urls(child)
        urls = []
        child.element_children.each do |nested|
          break if urls.size >= Limits::MAX_EMBED_SCAN
          next unless nested.name == 'iframe'

          src = nested['src'].to_s.strip
          urls << src if src.present?
        end
        text = child.text.to_s
        urls.concat(iframe_urls(text)) if text.present? && text.bytesize <= Limits::MAX_EMBED_HTML_BYTES
        urls.uniq.first(Limits::MAX_EMBED_SCAN)
      rescue StandardError
        []
      end

      def iframe_urls(html)
        text = html.to_s
        return [] if text.blank? || text.bytesize > Limits::MAX_EMBED_HTML_BYTES

        urls = []
        Nokogiri::HTML.fragment(text).css('iframe').each do |node|
          break if urls.size >= Limits::MAX_EMBED_SCAN

          src = node['src'].to_s.strip
          urls << src if src.present?
        end
        urls
      rescue StandardError
        []
      end

      def poster_row
        primary = @large.first || @small.first
        return nil if primary.nil?

        secondary = @large.first && @small.first && @small.first.logical != primary.logical ? @small.first : nil
        candidate = {
          'url' => primary.logical,
          'kind' => 'image',
          'role' => 'poster',
          'origin' => 'rss_thumb',
        }
        candidate['fetch_url'] = primary.fetch if primary.fetch != primary.logical
        if secondary
          candidate['fallbacks'] = [secondary.logical]
          candidate['fetch_fallbacks'] = [secondary.fetch] if secondary.fetch != secondary.logical
        end
        hide = [primary.logical, primary.fetch]
        hide << secondary.logical << secondary.fetch if secondary
        { candidate: candidate, hide: hide }
      end

      def player_row(article_url, poster)
        chosen = PlayerResolver.choose(article_url, @players)
        return nil if chosen.nil? || chosen.url.blank?

        candidate = {
          'url' => chosen.url,
          'kind' => 'embed',
          'role' => 'player',
          'origin' => chosen.origin,
        }
        logical = poster && poster[:candidate]['url']
        candidate['poster_url'] = logical if logical.present?
        candidate['duration'] = @duration unless @duration.nil?
        { at: chosen.at.to_i, candidate: candidate }
      end
    end
  end
end
