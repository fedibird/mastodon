# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Source text is untrusted. Stored text is plain, with tags removed.
    # Mentions, hashtags, and preview cards are not extracted from it.
    module Sanitizer
      module_function

      def plain(value)
        return '' if value.blank?

        fragment = Nokogiri::HTML.fragment(value.to_s)
        fragment.css('script,style,iframe,object,embed,link,meta').remove
        text = fragment.text.to_s
        text = text.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u2028\u2029]/, '')
        text.scrub.strip
      end

      def capped(value, limit = Limits::MAX_TEXT_BYTES)
        text = plain(value)
        return [text, false] if text.bytesize <= limit

        [text.byteslice(0, limit).to_s.scrub, true]
      end

      def title(value)
        plain(value).gsub(/\s+/, ' ').strip.slice(0, Limits::TITLE_CHARS)
      end
    end
  end
end
