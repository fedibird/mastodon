# frozen_string_literal: true

module ExternalBridge
  module RSS
    # RSS 1.0. Core elements use the RSS 1.0 URI. `rdf:about`, `rdf:resource`,
    # `rdf:Seq`, and `rdf:li` use the RDF URI. Prefixes are irrelevant.
    # Items are siblings of channel. The rdf:Seq in channel/items is the
    # published order; item elements that the sequence does not name are kept
    # after it. A generator that nests item under channel is accepted too.
    class RdfDocument
      def self.extract(document)
        new(document).extract
      end

      def initialize(document)
        @root = document.root
      end

      def extract
        channel = rss_child(@root, 'channel')
        return [nil, [], nil] if channel.nil?

        [channel, ordered_items(channel), image_url(channel)]
      end

      private

      def ordered_items(channel)
        nodes = rss_children(@root, 'item')
        rss_children(channel, 'item').each { |node| nodes << node unless nodes.include?(node) }
        sequence = sequence_urls(channel)
        return nodes if sequence.empty?

        pool = nodes.dup
        ordered = sequence.filter_map do |url|
          index = pool.index { |node| identities(node).include?(url) }
          pool.delete_at(index) if index
        end
        ordered + pool
      end

      def sequence_urls(channel)
        container = rss_child(channel, 'items')
        seq = rdf_child(container, 'seq')
        return [] if seq.nil?

        rdf_children(seq, 'li').filter_map { |node| XmlNames.attr_ns(node, 'resource', XmlNames::RDF).to_s.strip.presence }
      end

      def identities(node)
        [XmlNames.attr_ns(node, 'about', XmlNames::RDF), rss_text(node, 'link'), rss_text(node, 'guid')].filter_map { |value| value.to_s.strip.presence }
      end

      def image_url(channel)
        image = rss_child(channel, 'image')
        nested = rss_text(image, 'url')
        return nested if nested.present?

        resource = XmlNames.attr_ns(image, 'resource', XmlNames::RDF).to_s.strip
        listed = rss_children(@root, 'image')
        top = listed.find { |node| resource.present? && XmlNames.attr_ns(node, 'about', XmlNames::RDF).to_s.strip == resource }
        top ||= listed.first
        declared = rss_text(top, 'url')
        return declared if declared.present?
        return resource if resource.match?(%r{\Ahttps?://}i)

        nil
      end

      def rss_child(node, name)
        XmlNames.child(node, name, XmlNames::RSS1, case_insensitive: true)
      end

      def rss_children(node, name)
        XmlNames.children(node, name, XmlNames::RSS1, case_insensitive: true)
      end

      def rdf_child(node, name)
        XmlNames.child(node, name, XmlNames::RDF, case_insensitive: true)
      end

      def rdf_children(node, name)
        XmlNames.children(node, name, XmlNames::RDF, case_insensitive: true)
      end

      def rss_text(node, name)
        XmlNames.text(node, name, XmlNames::RSS1, case_insensitive: true)
      end
    end
  end
end
