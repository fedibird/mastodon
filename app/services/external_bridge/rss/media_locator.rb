# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Shared URL and field checks for article media. Group variants use the
    # same public-URL rule as a standalone enclosure. Player pages do not:
    # those go through PlayerResolver.
    module MediaLocator
      module_function

      def normalize(value, base)
        text = value.to_s.strip
        return nil if text.blank?
        return nil if dangerous?(text)

        MediaURL.normalize(absolute(text, base))
      end

      def mime_hint(value)
        label = value.to_s.split(';').first.to_s.strip.downcase
        return nil if label.blank? || %w(image video audio).include?(label)
        return nil unless label.match?(%r{\A[\w.+-]+/[\w.+-]+\z})

        label
      end

      def length_hint(value)
        return nil if value.blank?

        number = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
        return nil if number.negative? || number > 1_099_511_627_776

        number
      rescue ArgumentError, TypeError
        nil
      end

      def clean(value)
        text = Sanitizer.plain(value).gsub(/\s+/, ' ').strip
        return nil if text.blank?

        text.slice(0, Limits::MAX_MEDIA_DESCRIPTION)
      end

      def dangerous?(text)
        text.match?(/\A[a-z][a-z0-9+.-]*:/i) && !text.match?(/\Ahttps?:/i)
      end

      def absolute(text, base)
        return text if text.match?(/\Ahttps?:/i)
        return nil if base.blank?

        Addressable::URI.join(base, text).to_s
      rescue Addressable::URI::InvalidURIError
        nil
      end
    end
  end
end
