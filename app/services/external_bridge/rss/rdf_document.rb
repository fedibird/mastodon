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

      # Root items, then channel items that are not the same node. Membership
      # is object identity, which is what Node#== uses here. A linear index
      # replaces the previous scan of the remaining pool for every rdf:li.
      def ordered_items(channel)
        nodes = merged_items(channel)
        sequence = sequence_urls(channel)
        return nodes if sequence.empty?

        order_by_sequence(nodes, sequence)
      end

      def merged_items(channel)
        nodes = rss_children(@root, 'item')
        seen = {}.compare_by_identity
        nodes.each { |node| seen[node] = true }
        rss_children(channel, 'item').each do |node|
          next if seen[node]

          seen[node] = true
          nodes << node
        end
        nodes
      end

      def order_by_sequence(nodes, sequence)
        lists = Hash.new { |map, key| map[key] = [] }
        nodes.each do |node|
          identities(node).each { |value| lists[value] << node }
        end
        used = {}.compare_by_identity
        cursors = Hash.new(0)
        ordered = sequence.filter_map { |url| take_identity(lists, cursors, used, url) }
        ordered + nodes.reject { |node| used[node] }
      end

      def take_identity(lists, cursors, used, url)
        list = lists[url]
        index = cursors[url]
        index += 1 while index < list.length && used[list[index]]
        cursors[url] = index
        return nil if index >= list.length

        cursors[url] = index + 1
        node = list[index]
        used[node] = true
        node
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
