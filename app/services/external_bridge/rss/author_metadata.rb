# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Article-level display byline and author-image hint.
    #
    # Names are plain text. The image is a URL hint only: this class does not
    # fetch it, and it is not an article attachment. The displayed byline keeps
    # the existing priority. An extension image is bound to that byline only
    # when the extension name normalizes to the same text, so a conflicting
    # name cannot lend its picture to the standard author.
    #
    # Confirmed extension (element text, not an attribute):
    #   https://note.com  local names creatorName and creatorImage
    # A different URI, a missing namespace, or the same local name in another
    # namespace is ignored. Prefix spelling is not part of the match.
    class AuthorMetadata
      NOTE = 'https://note.com'
      SOURCE_DC = 'dc:creator'
      SOURCE_RSS = 'rss:author'
      SOURCE_ATOM = 'atom:author'
      SOURCE_NOTE_NAME = 'note:creatorName'
      SOURCE_NOTE_IMAGE = 'note:creatorImage'

      Result = Struct.new(:byline, :hints, keyword_init: true)

      def self.for_rss(node, namespaces)
        new(node, namespaces, atom: false).extract
      end

      def self.for_atom(node)
        new(node, XmlNames::ATOM, atom: true).extract
      end

      def initialize(node, namespaces, atom:)
        @node = node
        @namespaces = namespaces
        @atom = atom
      end

      def extract
        extension_name = first_name('creatorName', NOTE)
        image = first_image('creatorImage', NOTE)
        byline, source = displayed_byline(extension_name)
        Result.new(byline: byline, hints: hints_for(byline, source, extension_name, image))
      end

      private

      def displayed_byline(extension_name)
        standard_name, standard_source = standard_byline
        return [standard_name, standard_source] if standard_name.present?
        return [extension_name, SOURCE_NOTE_NAME] if extension_name.present?

        [nil, nil]
      end

      def standard_byline
        return atom_byline if @atom

        dc = first_name('creator', XmlNames::DC)
        return [dc, SOURCE_DC] if dc.present?

        author = first_name('author', @namespaces)
        return [author, SOURCE_RSS] if author.present?

        [nil, nil]
      end

      def atom_byline
        author = XmlNames.child(@node, 'author', XmlNames::ATOM)
        name = first_name_in(author, 'name', XmlNames::ATOM)
        return [name, SOURCE_ATOM] if name.present?

        [nil, nil]
      end

      def hints_for(byline, source, extension_name, image)
        hints = {}
        hints['byline_source'] = source if source.present?
        return hints if image.blank?

        hints['image_url'] = image
        hints['image_source'] = SOURCE_NOTE_IMAGE
        hints['image_name'] = extension_name if extension_name.present?
        hints['image_bound'] = extension_name.present? && byline.present? && extension_name == byline
        hints
      end

      def first_name(name, namespaces)
        first_name_in(@node, name, namespaces)
      end

      # The first sibling that is still non-empty after the display cleaner.
      # A blank or markup-only earlier sibling does not hide the next one.
      def first_name_in(node, name, namespaces)
        XmlNames.children(node, name, namespaces).each do |child|
          text = clean_name(child.text)
          return text if text.present?
        end
        nil
      end

      # The first sibling that survives the article image URL check. An empty
      # or rejected earlier sibling does not hide a later valid URL. Relative
      # URLs are not resolved here.
      def first_image(name, namespaces)
        XmlNames.children(@node, name, namespaces).each do |child|
          url = image_url(child.text)
          return url if url.present?
        end
        nil
      end

      def clean_name(value)
        Sanitizer.title(value).presence
      end

      def image_url(value)
        text = value.to_s.strip
        return nil if text.blank?
        return nil if text.match?(/\A[a-z][a-z0-9+.-]*:/i) && !text.match?(/\Ahttps?:/i)

        MediaURL.normalize(text)
      end
    end
  end
end
