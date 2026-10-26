# frozen_string_literal: true

module ExternalBridge
  module RSS
    # RSS 1.0. Parser has already removed namespaces, so rdf:RDF is RDF,
    # rdf:about is the about attribute, and dc:date is a date element.
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
        channel = child(@root, 'channel')
        return [nil, [], nil] if channel.nil?

        [channel, ordered_items(channel), image_url(channel)]
      end

      private

      def ordered_items(channel)
        nodes = children(@root, 'item')
        children(channel, 'item').each { |node| nodes << node unless nodes.include?(node) }
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
        container = child(channel, 'items')
        seq = child(container, 'seq')
        return [] if seq.nil?

        children(seq, 'li').filter_map { |node| node['resource'].to_s.strip.presence }
      end

      def identities(node)
        [node['about'], child_text(node, 'link'), child_text(node, 'guid')].filter_map { |value| value.to_s.strip.presence }
      end

      def image_url(channel)
        image = child(channel, 'image')
        nested = child_text(image, 'url')
        return nested if nested.present?

        resource = image&.[]('resource').to_s.strip
        listed = children(@root, 'image')
        top = listed.find { |node| resource.present? && node['about'].to_s.strip == resource }
        top ||= listed.first
        declared = child_text(top, 'url')
        return declared if declared.present?
        return resource if resource.match?(%r{\Ahttps?://}i)

        nil
      end

      def child(node, name)
        return nil if node.nil?

        node.elements.find { |element| element.name.casecmp(name).zero? }
      end

      def children(node, name)
        return [] if node.nil?

        node.elements.select { |element| element.name.casecmp(name).zero? }
      end

      def child_text(node, name)
        child(node, name)&.text.to_s.strip
      end
    end
  end
end
