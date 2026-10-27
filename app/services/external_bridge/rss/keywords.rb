# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Bounded keyword list stored for a later search or filter. Nothing here
    # turns a keyword into a hashtag or a timeline filter.
    module Keywords
      module_function

      def normalize(value)
        parts = value.is_a?(Array) ? value.flat_map { |item| item.to_s.split(',') } : value.to_s.split(',')
        seen = {}
        parts.filter_map do |part|
          text = part.gsub(/[\u0000-\u001f\u007f<>]/, ' ').squish
          next if text.blank? || text.length > Limits::MAX_KEYWORD_CHARS
          next if seen[text]

          seen[text] = true
          text
        end.first(Limits::MAX_KEYWORDS)
      end
    end
  end
end
