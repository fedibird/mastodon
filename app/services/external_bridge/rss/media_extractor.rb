# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Article media. Namespaces stay on the document, so `media:content`,
    # Atom `content`, and `content:encoded` stay distinct. Candidates are
    # taken from the body element the importer will actually use, plus
    # enclosures and Media RSS. Feed icons are not article media. A Media
    # RSS thumbnail uses its `url` attribute whenever that attribute exists;
    # the element text is only a compatibility source when it was omitted.
    # Thumbnail scope is content, then group, then item. A thumbnail used as
    # a video poster is not also an attachment. An explicit article image
    # with the same URL stays an attachment.
    #
    # A media:group is one logical candidate. Its renditions stay inside
    # that candidate. Another group, a loose content element, an enclosure,
    # and a body image stay separate even when a URL looks similar.
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

      # Parser calls this with the items it will actually consider. Walking
      # every item in a long feed built a preview, an HTML fragment, and
      # media candidates for entries that MAX_ITEMS then discarded.
      def self.index_items!(nodes)
        nodes = Array(nodes).compact
        return if nodes.empty?

        new(nodes.first.document).index_items!(nodes)
      end

      def initialize(document)
        @document = document
      end

      def index!
        index_items!(item_nodes)
      end

      def index_items!(nodes)
        nodes.each { |node| tag(node) }
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
        @group_path = []
        @group_sink = MediaGroup::Sink.new(
          raw: raw,
          posters: posters,
          base: base,
          article_url: article_href(node),
          scope: @group_path,
          budget: MediaGroup::Budget.new(Limits::MAX_GROUP_SCAN),
          scan: scan
        )
        node.element_children.each do |child|
          if media_group?(child)
            open_group(child)
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

      def open_group(child)
        return unless @group_sink.budget.take?

        MediaGroup.collect(child, @group_sink)
      end

      def collect_media(child, raw, posters, base)
        if media_group?(child)
          open_group(child)
          return
        end
        return add(raw, { url: MediaThumbnail.reference(child), mime: 'image', origin: 'media_thumbnail', base: base }) if MediaThumbnail.thumbnail?(child)
        # A title, description, or player from this namespace is not a file
        # URL, and neither is an element from another namespace.
        return unless MediaGroup.content?(child)

        row = MediaGroup.single(child, @group_sink)
        return if row.nil?

        stamp_scope!(row, { origin: row['origin'], kind: row['kind'] })
        raw << row
        remember_poster(posters, row['poster_url'], base) if row['kind'] == 'video'
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
        row = {
          'url' => source[:url],
          'kind' => source[:kind],
          'role' => 'attachment',
          'origin' => source[:origin],
          'mime_hint' => mime_hint(source[:mime]),
          'length_hint' => length_hint(source[:length]),
          'description' => clean(source[:description]),
          'poster_url' => source[:kind] == 'video' ? normalize(source[:poster], source[:base]) : nil,
        }.compact
        stamp_scope!(row, source)
        row
      end

      # Scope is used while binding thumbnails and then removed. It is not
      # stored and does not belong in the media digest.
      def stamp_scope!(row, source)
        if source[:origin] == 'media_thumbnail'
          row['_scope'] = @group_path.present? ? 'group' : 'item'
          row['_group_id'] = @group_path.last if @group_path.present?
        end
        return if @group_path.blank? || !%w(video audio).include?(source[:kind])

        row['_group_path'] = @group_path.dup
      end

      def remember_poster(posters, poster, base)
        absolute = normalize(poster, base)
        posters << absolute if absolute.present? && posters
      end

      # A group frame is always its own logical media. An independent
      # candidate is dropped only when its kind, role, and URL already belong
      # to an earlier independent candidate or to a variant of an earlier
      # group. A later group is not folded into that claim. Similar URLs are
      # not claims.
      def finalize(raw, posters)
        MediaScope.apply!(raw)
        claimed = {}
        kept = []
        raw.each do |candidate|
          next if candidate.delete('_consumed')

          release_scope!(candidate)
          next if hidden_thumbnail?(candidate, posters)
          next if skip_independent?(candidate, claimed)

          kept << candidate
          claim!(claimed, candidate)
          break if kept.size >= Limits::MAX_MEDIA_CANDIDATES
        end
        kept.each_with_index.map { |candidate, index| candidate.merge('position' => index) }
      end

      def skip_independent?(candidate, claimed)
        return false if candidate['group'].is_a?(Hash)

        claimed[exact_key(candidate['kind'], candidate['role'], candidate['url'])]
      end

      def claim!(claimed, candidate)
        claimed[exact_key(candidate['kind'], candidate['role'], candidate['url'])] = true
        Array(candidate.dig('group', 'variants')).each do |variant|
          role = variant['kind'] == 'embed' ? 'player' : 'attachment'
          claimed[exact_key(variant['kind'], role, variant['url'])] = true
        end
      end

      def exact_key(kind, role, url)
        "#{kind}\n#{role}\n#{url}"
      end

      def release_scope!(candidate)
        candidate.delete('_scope')
        candidate.delete('_group_id')
        candidate.delete('_group_path')
      end

      # Embed scan still hides its own thumb URL when that URL was not an
      # explicit article image. A media:thumbnail consumed as a poster is
      # already gone. An html or media:content image with the same URL stays.
      def hidden_thumbnail?(candidate, posters)
        return false unless candidate['kind'] == 'image' && candidate['role'] != 'poster'
        return false if MediaScope::INDEPENDENT_ORIGINS.include?(candidate['origin'])

        posters.include?(candidate['url'])
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
        MediaLocator.mime_hint(value)
      end

      def length_hint(value)
        MediaLocator.length_hint(value)
      end

      def clean(value)
        MediaLocator.clean(value)
      end

      def normalize(value, base)
        MediaLocator.normalize(value, base)
      end

      def absolute(text, base)
        MediaLocator.absolute(text, base)
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

      def child_ns(node, href, name)
        XmlNames.child(node, name, href)
      end

      def child_named(node, name)
        XmlNames.child(node, name, core_namespaces(node))
      end
    end
  end
end
