# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Reproducible public-feed stand-in. Item text and media URLs carry the
    # bytes; there is no single padding comment and no copied feed document.
    # Hosts are the reserved example names. TARGET_BYTES is the observed size
    # this phase compares, not a new product limit.
    module SyntheticFeed
      ITEMS = 1017
      TARGET_BYTES = 6_278_794
      SENTENCE = 'Synthetic article paragraph about a fictional river journey. '

      module_function

      def generate(items: ITEMS, target_bytes: TARGET_BYTES)
        shells = Array.new(items) { |index| item_shell(index) }
        fixed = channel_open.bytesize + channel_close.bytesize
        fixed += shells.sum { |prefix, suffix| prefix.bytesize + suffix.bytesize }
        raise ArgumentError, 'synthetic feed shell exceeds the target' if fixed > target_bytes

        remaining = target_bytes - fixed
        base, extra = remaining.divmod(items)
        body = +channel_open
        items.times do |index|
          prefix, suffix = shells[index]
          body << prefix << filler(base + (index < extra ? 1 : 0)) << suffix
        end
        body << channel_close
        body
      end

      def channel_open
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
          <channel>
          <title>Synthetic public feed</title>
          <link>https://feeds.example/synthetic</link>
          <description>Generated articles for a fictional site. Not a copied feed.</description>
        XML
      end

      def channel_close
        <<~XML
          </channel>
          </rss>
        XML
      end

      def item_shell(index)
        number = format('%04d', index + 1)
        prefix = <<~XML
          <item>
          <title>Synthetic note #{number}</title>
          <link>https://articles.example/notes/#{number}</link>
          <guid isPermaLink="false">synthetic-#{number}</guid>
          <enclosure url="https://media.example/audio/#{number}.mp3" type="audio/mpeg" length="128000"/>
          <description><![CDATA[<p>
        XML
        suffix = <<~XML
          </p><img src="https://media.example/images/#{number}.jpg" alt="illustration #{number}">]]></description>
          </item>
        XML
        [prefix, suffix]
      end

      def filler(bytes)
        return '' if bytes <= 0

        copies, rest = bytes.divmod(SENTENCE.bytesize)
        (SENTENCE * copies) + ('a' * rest)
      end
    end
  end
end
