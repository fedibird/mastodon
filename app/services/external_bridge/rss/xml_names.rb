# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Element and attribute selection by namespace URI plus local name.
    # The prefix string is not part of the match: `atom:link` and `a:link`
    # are the same element when they share the Atom URI.
    #
    # RSS 2.0 core elements have no namespace. RSS 1.0 core elements use the
    # RSS 1.0 URI. Dublin Core, Content, Media RSS, iTunes, RDF, and Atom stay
    # distinct, so a same-named element in another URI cannot take over a
    # standard field. Callers pass the URI list that is valid for that field.
    module XmlNames
      RSS1 = 'http://purl.org/rss/1.0/'
      RDF = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
      ATOM = 'http://www.w3.org/2005/Atom'
      DC = 'http://purl.org/dc/elements/1.1/'
      CONTENT = 'http://purl.org/rss/1.0/modules/content/'
      MEDIA = 'http://search.yahoo.com/mrss/'
      ITUNES = 'http://www.itunes.com/dtds/podcast-1.0.dtd'
      XML = 'http://www.w3.org/XML/1998/namespace'
      RSS_CORE = [nil, RSS1].freeze
      # RFC 4287 does not require atom:link/@type. When it is present, only an
      # HTML page representation is the article or site URL. ActivityPub
      # documents stay on the typed-link path instead.
      PAGE_TYPES = %w(text/html application/xhtml+xml).freeze
      ACTIVITY_TYPES = %w(application/activity+json application/ld+json).freeze

      module_function

      def children(node, name, namespaces, case_insensitive: false)
        return [] unless node.respond_to?(:element_children)

        node.element_children.select { |child| element?(child, name, namespaces, case_insensitive: case_insensitive) }
      end

      def child(node, name, namespaces, case_insensitive: false)
        children(node, name, namespaces, case_insensitive: case_insensitive).first
      end

      def text(node, name, namespaces, case_insensitive: false)
        child(node, name, namespaces, case_insensitive: case_insensitive)&.text.to_s.strip
      end

      def element?(node, name, namespaces, case_insensitive: false)
        return false unless node.is_a?(Nokogiri::XML::Element)
        return false unless same_name?(node.name, name, case_insensitive)

        href = node.namespace&.href
        allowed(namespaces).any? { |item| item.nil? ? href.nil? : item == href }
      end

      def attr_ns(node, name, namespace)
        return nil if node.nil?

        node.attribute_with_ns(name, namespace)&.value
      end

      # Page-link hrefs in the order Parser used before namespace selection:
      # every explicit rel="alternate" first, then links whose rel is omitted
      # (RFC 4287 section 4.2.7.2). self and enclosure are absent. Callers
      # validate each href with their own rules and keep the first success,
      # so a rejected leading URL does not hide a later candidate.
      def atom_page_hrefs(node, namespaces = [ATOM])
        explicit = []
        omitted = []
        children(node, 'link', namespaces).each do |link|
          next unless page_type?(link)

          href = link_href(link)
          next if href.empty?

          if explicit_alternate?(link)
            explicit << href
          elsif omitted_relation?(link)
            omitted << href
          end
        end
        explicit + omitted
      end

      def activitypub_hrefs(node)
        return [] unless node.respond_to?(:element_children)

        node.element_children.filter_map do |child|
          next unless activitypub_link?(child)
          next unless activitypub_relation?(child)
          next unless activitypub_type?(child)

          href = child['href'].to_s.strip
          href unless href.empty?
        end
      end

      # A single relation. Case-insensitive so `Alternate` still matches.
      # A value that contains whitespace is an HTML token list, not Atom.
      def explicit_alternate?(link)
        token = relation_token(link)
        return false if token.nil?

        token.casecmp?('alternate')
      end

      def omitted_relation?(link)
        raw = link['rel']
        raw.nil? || raw.strip.empty?
      end

      def relation_token(link)
        raw = link['rel']
        return nil if raw.nil?

        token = raw.strip
        return nil if token.empty? || token.match?(/\s/)

        token
      end

      def link_href(link)
        href = link['href'].to_s.strip
        href = link.text.to_s.strip if href.empty?
        href
      end

      def page_type?(link)
        type = media_type(link)
        type.empty? || PAGE_TYPES.include?(type)
      end

      def activitypub_type?(link)
        ACTIVITY_TYPES.include?(media_type(link))
      end

      def activitypub_relation?(link)
        raw = link['rel']
        return true if raw.blank?

        raw.to_s.split.any? { |rel| %w(alternate self).include?(rel.downcase) }
      end

      def activitypub_link?(child)
        return false unless child.is_a?(Nokogiri::XML::Element)
        return false unless child.name == 'link'

        href = child.namespace&.href
        href.nil? || href == ATOM || href == RSS1
      end

      def media_type(link)
        link['type'].to_s.split(';').first.to_s.strip.downcase
      end

      def same_name?(actual, expected, case_insensitive)
        return actual.casecmp?(expected) if case_insensitive

        actual == expected
      end

      def allowed(namespaces)
        namespaces.is_a?(Array) ? namespaces : [namespaces]
      end
      private_class_method :same_name?, :allowed, :explicit_alternate?, :omitted_relation?, :relation_token, :link_href
    end
  end
end
