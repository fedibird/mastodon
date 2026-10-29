# frozen_string_literal: true

module ExternalBridge
  module RSS
    # URL of one Media RSS thumbnail.
    #
    # The standard source is the un-namespaced `url` attribute. A same-named
    # attribute in another namespace is not that attribute. When the standard
    # attribute is present it is the only source, including when the value is
    # blank or later rejected. Some feeds put a single absolute http(s) URL
    # in the element text instead. That text is read only when the attribute
    # was omitted, the element has no child markup, and the whole trimmed
    # text is one explicit URL. Relative text is not resolved against a base.
    # The caller still resolves a relative attribute value.
    class MediaThumbnail
      BODY_HTTP = %r{\Ahttps?://[^\s<>"']+\z}i

      def self.reference(node)
        new(node).reference
      end

      def self.thumbnail?(node)
        node&.name == 'thumbnail' && node.namespace&.href == XmlNames::MEDIA
      end

      def initialize(node)
        @node = node
      end

      def reference
        return nil unless self.class.thumbnail?(@node)

        # Node#attribute matches the local name in every namespace, so a
        # leading other:url would hide the standard attribute or block the
        # text fallback. [] and attribute_with_ns(..., nil) are the
        # un-namespaced attribute only.
        attribute = @node.attribute_with_ns('url', nil)
        return attribute.value if attribute

        body_reference
      end

      private

      def body_reference
        return nil unless textual_body?

        text = @node.text.strip
        return nil unless text.match?(BODY_HTTP)
        return nil if text.scan(%r{https?://}i).size != 1

        text
      end

      # Child elements would concatenate their text into `node.text`. CDATA
      # is text, not an element. Anything else is mixed content.
      def textual_body?
        @node.children.all? { |child| child.text? || child.cdata? }
      end
    end
  end
end
