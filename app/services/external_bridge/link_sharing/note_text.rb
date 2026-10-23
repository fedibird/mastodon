# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Allowlist text for a reference note. Reads the canonical URL, the
    # source protocol, and the source title. It does not read a projection
    # body, spoiler, article title, byline, attachment, or poll.
    class NoteText
      PROTOCOL_LABELS = {
        'rss' => 'RSS',
        'atom' => 'Atom',
      }.freeze
      TITLE_LIMIT = 120

      def self.canonical_url!(resource)
        ArticleURL.normalize!(resource&.canonical_url)
      rescue Error
        raise Error, :canonical_url_invalid
      end

      def self.compose(source:, canonical_url:)
        lines = []
        title = sanitize_title(source&.title)
        lines << title if title.present?
        label = PROTOCOL_LABELS[source&.protocol.to_s]
        lines << label if label.present?
        lines << canonical_url
        lines.join("\n")
      end

      # Markup is omitted rather than parsed. @ and # are removed so the
      # title cannot become a mention or a hashtag.
      def self.sanitize_title(value)
        raw = value.to_s
        return '' if raw.match?(/[<>]/)

        text = raw.gsub(/[\u0000-\u001f\u007f]/, ' ').tr('@#', '').squish
        text.length > TITLE_LIMIT ? text[0, TITLE_LIMIT] : text
      end
    end
  end
end
