# frozen_string_literal: true

module ExternalBridge
  module RSS
    Item = Struct.new(:key, :title, :body, :canonical_url, :byline, :author_hints, :published_at, :truncated, :media, :keywords, :activitypub_url, :activitypub_explicit, :activitypub_sample_url, keyword_init: true)
    Feed = Struct.new(:protocol, :title, :site_url, :items, :icon_hints, :activitypub_hint, :activitypub_generator_hint, keyword_init: true) do
      # The feed-declared image URLs, best candidate first. They are raw text
      # here (possibly relative); the icon job resolves and validates them.
      def icon_hints
        self[:icon_hints] || []
      end
    end

    # RSS 1.0 (RDF), RSS 2.0, and Atom. External entities are not resolved.
    # RSS 2.0 and RSS 1.0 are recognized by the root element's local name.
    # Atom also requires the Atom namespace URI, so a foreign element named
    # `feed` is not a feed. Content-Type is not consulted. Namespaces stay on
    # the document: fields are chosen by URI and local name, so element order
    # and prefix spelling do not matter.
    class Parser
      ICON_HINT_ORDER = %w(atom_icon rss_image itunes_image atom_logo).freeze

      def self.parse!(body, budget: DocumentBudget::Budget.default)
        new(body, budget: budget).parse!
      end

      def initialize(body, budget: DocumentBudget::Budget.default)
        @body = body.to_s
        @budget = budget
      end

      def parse!
        # The pull parser enforces the byte and structure budgets and requires
        # a well-formed document through to the end. Recovery is off, so a
        # truncated tail is invalid_xml rather than a feed missing its last
        # tags. The DOM pass only runs after that walk returns.
        source = DocumentBudget.check!(@body, budget: @budget)
        document = Nokogiri::XML(source) { |config| config.strict.nonet.noblanks.nohuge }
        raise Error, :invalid_xml if document.root.nil?

        # Media RSS `content` and Atom `content` share a local name. Mark the
        # body element and candidates while the namespace URIs are still present.
        MediaExtractor.index!(document)
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
        namespaces = core_namespaces(document.root)
        channel = XmlNames.child(document.root, 'channel', namespaces)
        raise Error, :malformed_feed if channel.nil?

        items = XmlNames.children(channel, 'item', namespaces).first(Limits::MAX_ITEMS).filter_map { |node| rss_item(node) }
        Feed.new(
          protocol: 'rss',
          title: Sanitizer.title(XmlNames.text(channel, 'title', namespaces)),
          site_url: rss_link(channel),
          items: items,
          icon_hints: icon_hints(rss_icon_pairs(channel)),
          **feed_activitypub(channel, items)
        )
      end

      def rss_icon_pairs(channel)
        namespaces = core_namespaces(channel)
        image = XmlNames.child(channel, 'image', namespaces)
        itunes = XmlNames.child(channel, 'image', XmlNames::ITUNES)
        [
          ['rss_image', XmlNames.text(image, 'url', namespaces)],
          ['itunes_image', itunes&.[]('href')],
        ]
      end

      def parse_rdf(document)
        channel, nodes, image_url = RdfDocument.extract(document)
        raise Error, :malformed_feed if channel.nil?

        items = nodes.first(Limits::MAX_ITEMS).filter_map { |node| rss_item(node) }
        Feed.new(
          protocol: 'rss',
          title: Sanitizer.title(XmlNames.text(channel, 'title', core_namespaces(channel))),
          site_url: rss_link(channel),
          items: items,
          icon_hints: icon_hints([['rss_image', image_url]]),
          **feed_activitypub(channel, items)
        )
      end

      def parse_atom(document)
        feed = document.root
        raise Error, :malformed_feed unless feed.name.to_s.casecmp?('feed') && feed.namespace&.href == XmlNames::ATOM

        items = XmlNames.children(feed, 'entry', XmlNames::ATOM).first(Limits::MAX_ITEMS).filter_map { |node| atom_item(node) }
        hints = [['atom_icon', XmlNames.text(feed, 'icon', XmlNames::ATOM)], ['atom_logo', XmlNames.text(feed, 'logo', XmlNames::ATOM)]]
        Feed.new(
          protocol: 'atom',
          title: Sanitizer.title(XmlNames.text(feed, 'title', XmlNames::ATOM)),
          site_url: atom_link(feed),
          items: items,
          icon_hints: icon_hints(hints),
          **feed_activitypub(feed, items)
        )
      end

      def rss_item(node)
        namespaces = core_namespaces(node)
        about = XmlNames.attr_ns(node, 'about', XmlNames::RDF).to_s.strip.presence
        link = safe_url(XmlNames.text(node, 'link', namespaces).presence || about, item: true)
        key = XmlNames.text(node, 'guid', namespaces).presence || about || link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(raw_body(node))
        author = AuthorMetadata.for_rss(node, namespaces)
        Item.new(
          key: key.strip,
          title: Sanitizer.title(XmlNames.text(node, 'title', namespaces)),
          body: body,
          canonical_url: link,
          byline: author.byline,
          author_hints: author.hints,
          published_at: PublicationTime.parse(XmlNames.text(node, 'pubDate', namespaces)) || PublicationTime.parse(XmlNames.text(node, 'date', XmlNames::DC)),
          truncated: truncated,
          media: media_for(node),
          keywords: keywords_for(node),
          **activitypub_fields(node, link, key)
        )
      end

      def atom_item(node)
        key = XmlNames.text(node, 'id', XmlNames::ATOM).presence
        link = atom_link(node, item: true)
        key ||= link
        return nil if key.blank?

        body, truncated = Sanitizer.capped(raw_body(node))
        author = AuthorMetadata.for_atom(node)
        Item.new(
          key: key.strip,
          title: Sanitizer.title(XmlNames.text(node, 'title', XmlNames::ATOM)),
          body: body,
          canonical_url: link,
          byline: author.byline,
          author_hints: author.hints,
          published_at: PublicationTime.parse(XmlNames.text(node, 'published', XmlNames::ATOM)) || PublicationTime.parse(XmlNames.text(node, 'updated', XmlNames::ATOM)),
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
        XmlNames.activitypub_hrefs(node).each do |href|
          url = safe_url(href, item: true)
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
        namespaces = node.namespace&.href == XmlNames::ATOM ? XmlNames::ATOM : core_namespaces(node)
        XmlNames.text(node, 'generator', namespaces).first(200).match?(/\b(mastodon|misskey|pixelfed|pleroma|akkoma|gotosocial|friendica|firefish|sharkey|iceshrimp)\b/i)
      end

      # RSS `link` is the element text in this document's core namespace.
      # An Atom `link`, including rel="self", is a different element.
      def rss_link(node, item: false)
        safe_url(XmlNames.text(node, 'link', core_namespaces(node)), item: item)
      end

      def core_namespaces(node)
        XmlNames.core_namespaces(node&.document&.root)
      end

      # Explicit rel="alternate" outranks a link whose rel is omitted. Each
      # href is checked, and a rejected one does not hide the next candidate.
      # self and enclosure are not page URLs. With no accepted link the result
      # is nil; the entry id is left unchanged by the caller.
      def atom_link(node, item: false)
        XmlNames.atom_page_hrefs(node).each do |href|
          url = safe_url(href, item: item)
          return url if url.present?
        end
        nil
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

      def raw_body(node)
        preview = node.instance_variable_get(:@external_rss_preview)
        return preview.body if preview

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

      def safe_url(value, item: false)
        text = value.to_s.strip
        return nil if text.blank?

        CanonicalURL.normalize!(text, item: item)
      rescue Error
        nil
      end
    end
  end
end
