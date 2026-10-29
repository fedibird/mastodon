# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Article media. Namespaces stay on the document, so `media:content`,
    # Atom `content`, and `content:encoded` stay distinct. Candidates are
    # taken from the body element the importer will actually use, plus
    # enclosures and Media RSS. Feed icons are not article media. A video
    # poster is not also stored as an image attachment. A Media RSS
    # thumbnail uses its `url` attribute whenever that attribute exists;
    # the element text is only a compatibility source when it was omitted.
    class MediaExtractor
      Preview = Struct.new(:body, :candidates, :keywords, keyword_init: true)
      ATOM = XmlNames::ATOM
      CONTENT = XmlNames::CONTENT
      MEDIA = XmlNames::MEDIA
      ITUNES = XmlNames::ITUNES
      XML = XmlNames::XML
      VIDEO_MIME = %w(video/mp4 video/webm video/ogg video/quicktime).freeze
      HLS_MIME = %w(application/vnd.apple.mpegurl application/x-mpegurl).freeze
      AUDIO_EXT = %w(.mp3 .m4a .aac .ogg .oga .wav .flac .opus).freeze
      VIDEO_EXT = %w(.mp4 .webm .ogv .mov .m3u8).freeze
      IMAGE_EXT = %w(.jpg .jpeg .png .gif .webp).freeze

      def self.index!(document)
        new(document).index!
      end

      def initialize(document)
        @document = document
      end

      def index!
        item_nodes.each { |node| tag(node) }
      end

      private

      def item_nodes
        @document.xpath('//*[local-name()="item" or local-name()="entry"]').select { |node| item_node?(node) }
      end

      def item_node?(node)
        XmlNames.element?(node, 'item', core_namespaces(node)) || XmlNames.element?(node, 'entry', XmlNames::ATOM)
      end

      def tag(node)
        body_node = choose_body(node)
        raw = []
        posters = []
        base = base_for(node)
        scan = EmbedScan.new
        node.element_children.each do |child|
          if media_group?(child)
            child.element_children.each do |nested|
              scan.observe(nested, raw.size)
              collect(nested, body_node, raw, posters, base)
            end
          else
            scan.observe(child, raw.size)
            collect(child, body_node, raw, posters, base)
          end
          scan.note_html_at(raw.size) if child.equal?(body_node)
        end
        scan.finish_html(html_for(body_node))
        scan.apply!(raw, posters, article_href(node))
        preview = Preview.new(body: body_node&.text.to_s, candidates: finalize(raw, posters), keywords: scan.keywords)
        node.instance_variable_set(:@external_rss_preview, preview)
      end

      def choose_body(node)
        return atom_body(node) if entry?(node)

        encoded = child_ns(node, CONTENT, 'encoded')
        description = child_named(node, 'description')
        if podcast_audio?(node)
          # Some podcast platforms leave only their ad-choice boilerplate in
          # both general-purpose fields, while the actual episode description
          # is in iTunes subtitle. Preserve substantive RSS descriptions.
          return encoded if substantive_podcast_body?(encoded)
          return description if substantive_podcast_body?(description)

          subtitle = child_ns(node, ITUNES, 'subtitle')
          return subtitle if subtitle&.text.present?
        end
        return encoded if encoded&.text.present?
        return description if description&.text.present?

        encoded || description
      end

      def podcast_audio?(node)
        node.element_children.any? do |child|
          next false unless XmlNames.element?(child, 'enclosure', core_namespaces(child))

          child['type'].to_s.downcase.start_with?('audio/') ||
            %w(.mp3 .m4a .aac .ogg .oga .wav .flac .opus).include?(File.extname(Addressable::URI.parse(child['url'].to_s).path.to_s).downcase)
        rescue Addressable::URI::InvalidURIError
          false
        end
      end

      def substantive_podcast_body?(candidate)
        return false if candidate.nil?

        # Only a recognized, *standalone* ad notice is disregarded. All other
        # content remains authoritative, even when it mentions advertising.
        text = candidate.text.to_s.gsub(/<[^>]+>/, ' ').squish
        return false if text.blank?

        !text.match?(%r{\ALearn more about your ad choices\.\s+Visit\s+(?:https?://)?podcastchoices\.com/adchoices\.?\z}i)
      end

      def atom_body(node)
        content = child_ns(node, ATOM, 'content')
        summary = child_ns(node, ATOM, 'summary')
        return content if content&.text.present?
        return summary if summary&.text.present?

        content || summary
      end

      def collect(child, body_node, raw, posters, base)
        return collect_enclosure(child, raw, base) if enclosure?(child)
        return collect_media(child, raw, posters, base) if media?(child)
        return if child != body_node

        MediaHtml.extract(html_for(body_node), base, raw, posters)
      end

      def enclosure?(child)
        return true if XmlNames.element?(child, 'enclosure', core_namespaces(child))
        return false unless XmlNames.element?(child, 'link', ATOM)

        child['rel'].to_s.downcase == 'enclosure'
      end

      def collect_enclosure(child, raw, base)
        url = child.name == 'enclosure' ? child['url'] : child['href']
        add(raw, { url: url, mime: child['type'], length: child['length'], origin: 'enclosure', base: base })
      end

      def media?(child)
        child.namespace&.href == MEDIA && %w(content thumbnail group).include?(child.name)
      end

      def media_group?(child)
        child.name == 'group' && child.namespace&.href == MEDIA
      end

      def collect_media(child, raw, posters, base)
        return child.element_children.each { |nested| collect_media(nested, raw, posters, base) } if media_group?(child)
        return add(raw, { url: MediaThumbnail.reference(child), mime: 'image', origin: 'media_thumbnail', base: base }) if MediaThumbnail.thumbnail?(child)
        # Nested groups reach this method without the outer namespace check.
        # A thumbnail or group from another namespace is not media, and its
        # text must not become a content URL.
        return if %w(thumbnail group).include?(child.name)

        poster = MediaThumbnail.reference(child.element_children.find { |nested| MediaThumbnail.thumbnail?(nested) })
        description = child['description'].presence || media_description_text(child)
        add(raw, {
              url: child['url'].presence || child.text,
          mime: child['medium'].presence || child['type'],
          length: child['fileSize'],
          origin: 'media_rss',
          base: base,
          description: description,
          poster: poster,
          posters: posters,
            })
      end

      def add(raw, source)
        absolute = normalize(source[:url], source[:base])
        return if absolute.blank?

        kind = kind_for(source[:mime], absolute)
        return if kind.blank?

        raw << candidate(source.merge(url: absolute, kind: kind))
        remember_poster(source[:posters], source[:poster], source[:base]) if kind == 'video'
      end

      def candidate(source)
        {
          'url' => source[:url],
          'kind' => source[:kind],
          'role' => 'attachment',
          'origin' => source[:origin],
          'mime_hint' => mime_hint(source[:mime]),
          'length_hint' => length_hint(source[:length]),
          'description' => clean(source[:description]),
          'poster_url' => source[:kind] == 'video' ? normalize(source[:poster], source[:base]) : nil,
        }.compact
      end

      def remember_poster(posters, poster, base)
        absolute = normalize(poster, base)
        posters << absolute if absolute.present? && posters
      end

      def finalize(raw, posters)
        claim_thumbnails(raw, posters)
        seen = {}
        kept = []
        raw.each do |candidate|
          next if candidate['kind'] == 'image' && candidate['role'] != 'poster' && posters.include?(candidate['url'])

          key = "#{candidate['kind']}\n#{candidate['url']}"
          next if seen[key]

          seen[key] = true
          kept << candidate
          break if kept.size >= Limits::MAX_MEDIA_CANDIDATES
        end
        kept.each_with_index.map { |candidate, index| candidate.merge('position' => index) }
      end

      # A Media RSS thumbnail beside a video is that video's poster, not a
      # second image attachment.
      def claim_thumbnails(raw, posters)
        return unless raw.any? { |candidate| candidate['kind'] == 'video' }

        raw.each do |candidate|
          next unless candidate['origin'] == 'media_thumbnail'

          posters << candidate['url']
          video = raw.find { |item| item['kind'] == 'video' && item['poster_url'].blank? }
          video['poster_url'] = candidate['url'] if video
        end
      end

      def html_for(node)
        return nil if node.nil? || plain_text?(node)
        return node.element_children.map(&:to_xml).join if node['type'].to_s.downcase == 'xhtml'

        node.text
      end

      def plain_text?(node)
        type = node['type'].to_s.downcase
        return true if type == 'text'
        return false if %w(html xhtml).include?(type)

        node.namespace&.href == ATOM
      end

      def kind_for(mime, url)
        label = mime.to_s.split(';').first.to_s.strip.downcase
        return 'image' if label.start_with?('image/') && label != 'image/svg+xml'
        return 'video' if VIDEO_MIME.include?(label) || HLS_MIME.include?(label)
        return 'audio' if label.start_with?('audio/') && label != 'audio/x-unknown'
        return label if %w(image video audio).include?(label)

        kind_from_extension(url)
      end

      def kind_from_extension(url)
        extension = File.extname(Addressable::URI.parse(url.to_s).path.to_s).downcase
        return nil if extension == '.svg'
        return 'image' if IMAGE_EXT.include?(extension)
        return 'video' if VIDEO_EXT.include?(extension)
        return 'audio' if AUDIO_EXT.include?(extension)

        nil
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def mime_hint(value)
        label = value.to_s.split(';').first.to_s.strip.downcase
        return nil if label.blank? || %w(image video audio).include?(label)
        return nil unless label.match?(%r{\A[\w.+-]+/[\w.+-]+\z})

        label
      end

      def length_hint(value)
        return nil if value.blank?

        number = Integer(value.to_s, 10)
        return nil if number.negative? || number > 1_099_511_627_776

        number
      rescue ArgumentError, TypeError
        nil
      end

      def clean(value)
        text = Sanitizer.plain(value).gsub(/\s+/, ' ').strip
        return nil if text.blank?

        text.slice(0, Limits::MAX_MEDIA_DESCRIPTION)
      end

      def normalize(value, base)
        text = value.to_s.strip
        return nil if text.blank?
        return nil if dangerous_scheme?(text)

        MediaURL.normalize(absolute(text, base))
      end

      def dangerous_scheme?(text)
        text.match?(/\A[a-z][a-z0-9+.-]*:/i) && !text.match?(/\Ahttps?:/i)
      end

      def absolute(text, base)
        return text if text.match?(/\Ahttps?:/i)
        return nil if base.blank?

        Addressable::URI.join(base, text).to_s
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def base_for(node)
        xml_base(node) || link_base(node) || channel_base(node)
      end

      def xml_base(node)
        current = node
        while current.is_a?(Nokogiri::XML::Element)
          value = current.attribute_with_ns('base', XML)&.value
          absolute = MediaURL.normalize(value) if value.present?
          return absolute if absolute.present?

          current = current.parent
        end
        nil
      end

      def article_href(node)
        href = entry?(node) ? atom_href(node) : link_value(node)
        href.presence || XmlNames.attr_ns(node, 'about', XmlNames::RDF).to_s.strip.presence
      end

      def link_base(node)
        href = entry?(node) ? atom_href(node) : link_value(node)
        found = MediaURL.normalize(href)
        found = page_path_base(href) if found.blank? && entry?(node)
        found || absolute_against(href, channel_base(node))
      end

      # CanonicalURL accepts item queries that MediaURL does not store. The
      # path of that same absolute URL is still the base for a relative image.
      def page_path_base(href)
        text = href.to_s.strip
        return nil unless text.match?(/\Ahttps?:/i)

        MediaURL.normalize(text.sub(/\?.*\z/, '').sub(/#.*\z/, ''))
      end

      def link_value(node)
        child = child_named(node, 'link')
        child&.text.presence || child&.[]('href')
      end

      def channel_base(node)
        current = node.parent
        while current.is_a?(Nokogiri::XML::Element)
          href = container_href(current)
          found = MediaURL.normalize(href) if href.present?
          return found if found.present?

          current = current.parent
        end
        nil
      end

      def container_href(node)
        namespaces = core_namespaces(node)
        return atom_href(node) if XmlNames.element?(node, 'feed', ATOM, case_insensitive: true)
        return XmlNames.text(node, 'link', namespaces).presence if XmlNames.element?(node, 'channel', namespaces, case_insensitive: true)
        return XmlNames.text(node, 'link', namespaces).presence if XmlNames.element?(node, 'rdf', XmlNames::RDF, case_insensitive: true)

        nil
      end

      def absolute_against(value, base)
        return nil if value.blank? || base.blank?

        MediaURL.normalize(absolute(value, base))
      end

      # The same candidate Parser keeps for canonical_url / site_url. The
      # returned string is the raw href, so a player can still see an item id
      # query that CanonicalURL accepts and MediaURL does not store.
      def atom_href(node)
        item = entry?(node)
        XmlNames.atom_page_hrefs(node).each do |href|
          return href if canonical_page?(href, item: item)
        end
        nil
      end

      def canonical_page?(href, item:)
        text = href.to_s.strip
        return false if text.blank?

        CanonicalURL.normalize!(text, item: item)
        true
      rescue Error
        false
      end

      def core_namespaces(node)
        XmlNames.core_namespaces(node&.document&.root)
      end

      def entry?(node)
        XmlNames.element?(node, 'entry', ATOM)
      end

      def media_description_text(child)
        nested = child.element_children.find do |node|
          next false unless node.name == 'description'

          href = node.namespace&.href
          href.nil? || href == MEDIA
        end
        nested&.text
      end

      def child_ns(node, href, name)
        XmlNames.child(node, name, href)
      end

      def child_named(node, name)
        XmlNames.child(node, name, core_namespaces(node))
      end
    end
  end
end
