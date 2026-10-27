# frozen_string_literal: true

module ExternalBridge
  module RSS
    Item = Struct.new(:key, :title, :body, :canonical_url, :byline, :published_at, :truncated, :media, :keywords, :activitypub_url, :activitypub_explicit, :activitypub_sample_url, keyword_init: true)
    Feed = Struct.new(:protocol, :title, :site_url, :items, :icon_hints, :activitypub_hint, :activitypub_generator_hint, keyword_init: true) do
      # The feed-declared image URLs, best candidate first. They are raw text
      # here (possibly relative); the icon job resolves and validates them.
      def icon_hints
        self[:icon_hints] || []
      end
    end

    # RSS 1.0 (RDF), RSS 2.0, and Atom. External entities are not resolved.
    # The root element decides the format. Content-Type is not consulted.
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
        raise Error, :invalid_xml if document.root.nil?

        # Media RSS `content` and Atom `content` collide after namespaces
        # are removed, so candidates and the real body element are marked first.
        MediaExtractor.index!(document)
        document.remove_namespaces!
        case document.root.name.to_s.downcase
        when 'rss' then parse_rss(document)
        when 'feed' then parse_atom(document)
        when 'rdf' then parse_rdf(document)
        else raise Error, :malformed_feed
        end
      rescue Nokogiri::XML::SyntaxError
        raise Error, :invalid_xml
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
          icon_hints: icon_hints([['rss_image', channel.at_xpath('image/url')&.text]]),
          **feed_activitypub(channel, items)
        )
      end

      def parse_rdf(document)
        channel, nodes, image_url = RdfDocument.extract(document)
        raise Error, :malformed_feed if channel.nil?

        items = nodes.first(Limits::MAX_ITEMS).filter_map { |node| rss_item(node) }
        Feed.new(
          protocol: 'rss',
          title: Sanitizer.title(text_at(channel, 'title')),
          site_url: safe_url(text_at(channel, 'link')),
          items: items,
          icon_hints: icon_hints([['rss_image', image_url]]),
          **feed_activitypub(channel, items)
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
          icon_hints: icon_hints([['atom_icon', text_at(feed, 'icon')], ['atom_logo', text_at(feed, 'logo')]]),
          **feed_activitypub(feed, items)
        )
      end

      def rss_item(node)
        about = node['about'].to_s.strip.presence
        link = safe_url(text_at(node, 'link').presence || about, item: true)
        key = text_at(node, 'guid').presence || about || link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(raw_body(node, 'encoded', 'description'))
        Item.new(
          key: key.strip,
          title: Sanitizer.title(text_at(node, 'title')),
          body: body,
          canonical_url: link,
          byline: Sanitizer.title(text_at(node, 'creator').presence || text_at(node, 'author')),
          published_at: parse_time(text_at(node, 'pubDate')) || parse_time(text_at(node, 'date')),
          truncated: truncated,
          media: media_for(node),
          keywords: keywords_for(node),
          **activitypub_fields(node, link, key)
        )
      end

      def atom_item(node)
        key = text_at(node, 'id').presence
        link = atom_link(node, item: true)
        key ||= link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(raw_body(node, 'content', 'summary'))
        Item.new(
          key: key.strip,
          title: Sanitizer.title(text_at(node, 'title')),
          body: body,
          canonical_url: link,
          byline: Sanitizer.title(node.at_xpath('author/name')&.text),
          published_at: parse_time(text_at(node, 'published').presence || text_at(node, 'updated')),
          truncated: truncated,
          media: media_for(node),
          keywords: keywords_for(node),
          **activitypub_fields(node, link, key)
        )
      end

      # Typed alternate links are only hints; the probe must verify the JSON.
      # activitypub_url is that typed link alone. An ordinary permalink is
      # activitypub_sample_url and is not probed unless the feed sample admits it.
      def explicit_activitypub_url(node)
        node.xpath('link[@href]').each do |link|
          next unless link['rel'].blank? || link['rel'].to_s.split.any? { |rel| %w(alternate self).include?(rel) }
          next unless %w(application/activity+json application/ld+json).include?(link['type'].to_s.split(';').first.to_s.strip.downcase)

          url = safe_url(link['href'], item: true)
          return url if url.present?
        end
        nil
      end

      def activitypub_fields(node, link, identity)
        explicit = explicit_activitypub_url(node)
        if explicit.present?
          return { activitypub_url: explicit, activitypub_explicit: true, activitypub_sample_url: nil }
        end

        { activitypub_url: nil, activitypub_explicit: false, activitypub_sample_url: link || safe_url(identity, item: true) }
      end

      def feed_activitypub(node, items)
        generator = generator_hint?(node)
        { activitypub_hint: generator || items.any?(&:activitypub_explicit), activitypub_generator_hint: generator }
      end

      def generator_hint?(node)
        text_at(node, 'generator').first(200).match?(/\b(mastodon|misskey|pixelfed|pleroma|akkoma|gotosocial|friendica|firefish|sharkey|iceshrimp)\b/i)
      end

      def atom_link(node, item: false)
        alternate = node.at_xpath("link[@rel='alternate']")
        chosen = alternate || node.at_xpath('link[@href]')
        href = chosen&.[]('href')
        href = text_at(node, 'link') if href.blank?
        safe_url(href, item: item)
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

      def raw_body(node, *fallbacks)
        preview = node.instance_variable_get(:@external_rss_preview)
        return preview.body if preview

        fallbacks.each do |name|
          value = text_at(node, name).presence
          return value if value
        end
        nil
      end

      def media_for(node)
        preview = node.instance_variable_get(:@external_rss_preview)
        Array(preview&.candidates)
      end

      def keywords_for(node)
        preview = node.instance_variable_get(:@external_rss_preview)
        Array(preview&.keywords)
      end

      def text_at(node, name)
        node.at_xpath(name)&.text.to_s.strip
      end

      def safe_url(value, item: false)
        text = value.to_s.strip
        return nil if text.blank?

        CanonicalURL.normalize!(text, item: item)
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
