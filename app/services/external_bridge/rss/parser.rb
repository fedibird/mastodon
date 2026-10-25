# frozen_string_literal: true

module ExternalBridge
  module RSS
    Item = Struct.new(:key, :title, :body, :canonical_url, :byline, :published_at, :truncated, keyword_init: true)
    Feed = Struct.new(:protocol, :title, :site_url, :items, :icon_hints, keyword_init: true) do
      # The feed-declared image URLs, best candidate first. They are raw text
      # here (possibly relative); the icon job resolves and validates them.
      def icon_hints
        self[:icon_hints] || []
      end
    end

    # RSS 2.0 and Atom. External entities are not resolved.
    class Parser
      ICON_HINT_ORDER = %w(atom_icon rss_image atom_logo).freeze

      def self.parse!(body)
        new(body).parse!
      end

      def initialize(body)
        @body = body.to_s
      end

      def parse!
        document = Nokogiri::XML(@body) { |config| config.nonet.noblanks }
        raise Error, :malformed_feed if document.errors.any? && document.root.nil?
        raise Error, :malformed_feed if document.root.nil?

        document.remove_namespaces!
        root = document.root.name.to_s.downcase
        if root == 'rss'
          parse_rss(document)
        elsif root == 'feed'
          parse_atom(document)
        else
          raise Error, :malformed_feed
        end
      rescue Nokogiri::XML::SyntaxError
        raise Error, :malformed_feed
      end

      private

      def parse_rss(document)
        channel = document.at_xpath('/rss/channel')
        raise Error, :malformed_feed if channel.nil?

        items = channel.xpath('item').first(Limits::MAX_ITEMS).filter_map { |node| rss_item(node) }
        Feed.new(
          protocol: 'rss',
          title: Sanitizer.title(text_at(channel, 'title')),
          site_url: safe_url(text_at(channel, 'link')),
          items: items,
          icon_hints: icon_hints([['rss_image', channel.at_xpath('image/url')&.text]])
        )
      end

      def parse_atom(document)
        feed = document.at_xpath('/feed')
        raise Error, :malformed_feed if feed.nil?

        items = feed.xpath('entry').first(Limits::MAX_ITEMS).filter_map { |node| atom_item(node) }
        Feed.new(
          protocol: 'atom',
          title: Sanitizer.title(text_at(feed, 'title')),
          site_url: atom_link(feed) || safe_url(text_at(feed, 'link')),
          items: items,
          icon_hints: icon_hints([['atom_icon', text_at(feed, 'icon')], ['atom_logo', text_at(feed, 'logo')]])
        )
      end

      def rss_item(node)
        key = text_at(node, 'guid').presence
        link = safe_url(text_at(node, 'link'))
        key ||= link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(text_at(node, 'encoded').presence || text_at(node, 'description'))
        Item.new(
          key: key.strip,
          title: Sanitizer.title(text_at(node, 'title')),
          body: body,
          canonical_url: link,
          byline: Sanitizer.title(text_at(node, 'creator').presence || text_at(node, 'author')),
          published_at: parse_time(text_at(node, 'pubDate')),
          truncated: truncated
        )
      end

      def atom_item(node)
        key = text_at(node, 'id').presence
        link = atom_link(node)
        key ||= link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(text_at(node, 'content').presence || text_at(node, 'summary'))
        Item.new(
          key: key.strip,
          title: Sanitizer.title(text_at(node, 'title')),
          body: body,
          canonical_url: link,
          byline: Sanitizer.title(node.at_xpath('author/name')&.text),
          published_at: parse_time(text_at(node, 'published').presence || text_at(node, 'updated')),
          truncated: truncated
        )
      end

      def atom_link(node)
        alternate = node.at_xpath("link[@rel='alternate']")
        chosen = alternate || node.at_xpath('link[@href]')
        href = chosen&.[]('href')
        href = text_at(node, 'link') if href.blank?
        safe_url(href)
      end

      # A square site icon beats a feed image, and a feed image beats an
      # Atom logo (the Atom logo is specified as a 2:1 banner).
      def icon_hints(pairs)
        ranked = pairs.sort_by { |kind, _| ICON_HINT_ORDER.index(kind) || ICON_HINT_ORDER.size }
        ranked.filter_map do |kind, value|
          url = value.to_s.strip
          next if url.empty? || url.bytesize > Limits::MAX_KEY_BYTES

          { 'kind' => kind, 'url' => url }
        end.first(Limits::ICON_HINTS)
      end

      def text_at(node, name)
        node.at_xpath(name)&.text.to_s.strip
      end

      def safe_url(value)
        return nil if value.blank?

        CanonicalURL.normalize!(value)
      rescue Error
        nil
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
