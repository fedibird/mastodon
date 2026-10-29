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

      # RFC 4287 section 4.2.7.2: a missing rel means alternate. The value is
      # one relation, not an HTML token list. Comparison is case-insensitive
      # so `Alternate` still matches the registered token.
      def atom_page_href(node, namespaces = [ATOM])
        children(node, 'link', namespaces).each do |link|
          next unless page_relation?(link)
          next unless page_type?(link)

          href = link['href'].to_s.strip
          href = link.text.to_s.strip if href.empty?
          return href unless href.empty?
        end
        nil
      end

      def activitypub_href(node)
        return nil unless node.respond_to?(:element_children)

        node.element_children.each do |child|
          next unless activitypub_link?(child)
          next unless activitypub_relation?(child)
          next unless activitypub_type?(child)

          href = child['href'].to_s.strip
          return href unless href.empty?
        end
        nil
      end

      def page_relation?(link)
        raw = link['rel']
        return true if raw.nil? || raw.strip.empty?

        token = raw.strip
        return false if token.match?(/\s/)

        token.casecmp?('alternate')
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
      private_class_method :same_name?, :allowed
    end
  end
end
