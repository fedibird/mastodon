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
        @duration ||= duration_from(child)
        @keywords ||= keywords_from(child)
        remember_thumb(child, at)
        remember_embed(child, at)
        remember_player(child, at)
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

      def apply!(raw, posters, article_url)
        poster = poster_row
        if poster
          poster[:hide].each { |url| posters << url if url.present? }
        end
        rows = []
        rows << { at: @poster_at || raw.size, candidate: poster[:candidate] } if poster
        player = player_row(article_url, poster)
        rows << { at: player[:at], candidate: player[:candidate] } if player
        shift = 0
        rows.sort_by { |row| row[:at].to_i }.each do |row|
          raw.insert([row[:at].to_i + shift, raw.size].min, row[:candidate])
          shift += 1
        end
      end

      private

      def duration_from(child)
        return nil unless child.name == 'duration'

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

        child.text
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

      def remember_embed(child, at)
        return unless child.name == 'embed'
        return if child.namespace&.href == MediaExtractor::ATOM

        urls = embed_urls(child)
        return if urls.empty?

        @players << { priority: 1, at: at, origin: 'rss_embed', urls: urls }
      end

      def remember_player(child, at)
        urls = player_urls(child)
        return if urls.empty?

        @players << { priority: 2, at: at, origin: 'media_player', urls: urls }
      end

      def player_urls(child)
        if child.name == 'group' && child.namespace&.href == MediaExtractor::MEDIA
          return child.element_children.flat_map { |nested| player_urls(nested) }
        end
        return [] unless child.name == 'player' && child.namespace&.href == MediaExtractor::MEDIA

        [child['url'].to_s].reject(&:blank?)
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
