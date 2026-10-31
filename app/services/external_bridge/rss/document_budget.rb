# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Streaming budget for one document, applied before Parser builds a DOM.
    #
    # BodyReader limits how many bytes a feed response may contain. This
    # class is the parser's own gate, including when parse! is called with a
    # string that never passed through that reader. Sizes are bytes.
    #
    # The walk is Nokogiri's pull parser. It does not use attribute_hash or
    # namespaces, because those expand the current element into a subtree.
    # Recovery stays off, and HUGE is not set, so a truncated document is a
    # syntax error and libxml keeps its entity-amplification ceiling. One
    # text node is materialized by the reader and then counted. Crossing a
    # budget raises before the next node is visited and before the DOM parse.
    #
    # Depth counts elements. The root is depth 1, which is reader depth 0.
    # Attribute count includes xmlns declarations.
    class DocumentBudget
      Budget = Struct.new(
        :max_bytes,
        :max_depth,
        :max_elements,
        :max_attributes,
        :max_text_bytes,
        :max_attribute_bytes,
        keyword_init: true
      ) do
        def self.default
          new(
            max_bytes: Limits::MAX_PARSE_BYTES,
            max_depth: Limits::MAX_XML_DEPTH,
            max_elements: Limits::MAX_XML_ELEMENTS,
            max_attributes: Limits::MAX_XML_ATTRIBUTES,
            max_text_bytes: Limits::MAX_XML_TEXT_BYTES,
            max_attribute_bytes: Limits::MAX_XML_ATTRIBUTE_BYTES
          )
        end
      end

      ELEMENT = Nokogiri::XML::Reader::TYPE_ELEMENT
      TEXT = Nokogiri::XML::Reader::TYPE_TEXT
      CDATA = Nokogiri::XML::Reader::TYPE_CDATA
      COMMENT = Nokogiri::XML::Reader::TYPE_COMMENT

      def self.check!(body, budget: Budget.default)
        new(body, budget).check!
      end

      def initialize(body, budget)
        @body = body.to_s
        @budget = budget
      end

      def check!
        raise Error, :oversized_feed if @body.bytesize > @budget.max_bytes

        walk!
        nil
      rescue Nokogiri::XML::SyntaxError => e
        raise Error, amplification?(e) ? :oversized_feed : :invalid_xml
      end

      private

      def walk!
        elements = 0
        reader.each do |node|
          elements = visit!(node, elements)
        end
      end

      def reader
        Nokogiri::XML::Reader.new(@body) { |config| config.nonet.noent.nohuge }
      end

      def visit!(node, elements)
        case node.node_type
        when ELEMENT
          count_element!(node, elements)
        when TEXT, CDATA, COMMENT
          limit_bytes!(node.value, @budget.max_text_bytes)
          elements
        else
          elements
        end
      end

      def count_element!(node, elements)
        elements += 1
        raise Error, :oversized_feed if elements > @budget.max_elements
        raise Error, :oversized_feed if node.depth + 1 > @budget.max_depth

        limit_attributes!(node)
        elements
      end

      def limit_attributes!(node)
        count = node.attribute_count
        raise Error, :oversized_feed if count > @budget.max_attributes

        index = 0
        while index < count
          limit_bytes!(node.attribute_at(index), @budget.max_attribute_bytes)
          index += 1
        end
      end

      def limit_bytes!(value, limit)
        raise Error, :oversized_feed if value.to_s.bytesize > limit
      end

      def amplification?(exception)
        exception.message.include?('amplification')
      end
    end
  end
end
