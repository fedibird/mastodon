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

      # Small items for structure tests. This is not the 6 MiB fixture.
      def compact(items:, description: 'Synthetic note.')
        body = +channel_open
        items.times { |index| body << compact_item(index, description: description) }
        body << channel_close
        body
      end

      def compact_item(index, description: 'Synthetic note.')
        number = format('%04d', index + 1)
        <<~XML
          <item>
          <title>Synthetic note #{number}</title>
          <link>https://articles.example/notes/#{number}</link>
          <guid isPermaLink="false">synthetic-#{number}</guid>
          <description>#{description}</description>
          </item>
        XML
      end

      # Forty complete items, then a start tag that never closes.
      def broken_after(valid_items: 40)
        body = +channel_open
        valid_items.times { |index| body << compact_item(index) }
        body << '<item><title>broken'
        body
      end

      def unclosed_cdata(valid_items: 40)
        body = +channel_open
        valid_items.times { |index| body << compact_item(index) }
        body << '<item><description><![CDATA[unterminated'
        body
      end

      def missing_close(valid_items: 40)
        body = +channel_open
        valid_items.times { |index| body << compact_item(index) }
        body << '</channel>'
        body
      end

      # Root is depth 1. `depth` is the number of nested elements.
      def deep(depth)
        inner = 'x'
        depth.times { |index| inner = "<e#{index}>#{inner}</e#{index}>" }
        inner
      end

      def repeated_elements(count)
        %(<r>#{'<e/>' * count}</r>)
      end

      def repeated_attributes(count, value: 'v')
        attrs = Array.new(count) { |index| %(a#{index}="#{value}") }.join(' ')
        %(<r #{attrs}/>)
      end

      def text_node(copies, char: 'a')
        %(<r>#{char * copies}</r>)
      end

      # One HTML description per item, so media extraction has work to do.
      # The markup is generated. It is not copied from a public feed.
      def html_items(count, html: '<p><img src="https://media.example/images/note.jpg" alt="picture"></p>')
        body = +channel_open
        count.times { |index| body << html_item(index, html) }
        body << channel_close
        body
      end

      def html_item(index, html)
        number = format('%04d', index + 1)
        <<~XML
          <item>
          <title>Synthetic note #{number}</title>
          <link>https://articles.example/notes/#{number}</link>
          <guid isPermaLink="false">synthetic-#{number}</guid>
          <enclosure url="https://media.example/audio/#{number}.mp3" type="audio/mpeg" length="128000"/>
          <description><![CDATA[#{html}]]></description>
          </item>
        XML
      end

      # RSS 1.0. rdf:Seq lists the items from last to first, which is the
      # order Parser must keep. Unlisted items are not generated.
      def rdf_feed(count)
        entries = count.times.map { |index| rdf_entry(index) }
        sequence = entries.reverse.map { |entry| %(<rdf:li rdf:resource="#{entry[:about]}"/>) }.join
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
            <channel rdf:about="https://news.example/">
              <title>Synthetic RDF</title>
              <link>https://news.example/</link>
              <items><rdf:Seq>#{sequence}</rdf:Seq></items>
            </channel>
            #{entries.map { |entry| entry[:xml] }.join}
          </rdf:RDF>
        XML
      end

      def rdf_entry(index)
        number = format('%04d', index + 1)
        about = "https://articles.example/notes/#{number}"
        xml = <<~XML
          <item rdf:about="#{about}">
            <title>Synthetic note #{number}</title>
            <link>#{about}</link>
          </item>
        XML
        { about: about, number: number, xml: xml }
      end

      def duplicate_guids
        shared = compact_item(0).sub('synthetic-0001', 'synthetic-shared').sub('Synthetic note 0001', 'First shared')
        again = compact_item(1).sub('synthetic-0002', 'synthetic-shared').sub('Synthetic note 0002', 'Second shared')
        body = +channel_open
        body << shared << again
        3.upto(41) { |index| body << compact_item(index) }
        body << channel_close
        body
      end

      # rss, channel, title, link, description, and 40 items of five elements.
      ELEMENT_FEED_SHELL = 205
      # Only rss@version. Item guids in this generator have no attributes.
      ELEMENT_FEED_SHELL_ATTRIBUTES = 1

      # A well-formed RSS document with exactly `elements` element start tags.
      # Forty items are real. The rest are empty <e/> nodes.
      def element_cap_feed(elements:)
        raise ArgumentError, 'element target is below the 40 item shell' if elements < ELEMENT_FEED_SHELL

        body = element_feed_open
        body << ('<e/>' * (elements - ELEMENT_FEED_SHELL))
        body << '</channel></rss>'
        body
      end

      # attribute_count summed across the document, including rss@version.
      # Filler attributes are packed at 64 per element, under the per-element cap.
      def attribute_total_feed(attributes:)
        needed = attributes - ELEMENT_FEED_SHELL_ATTRIBUTES
        raise ArgumentError, 'attribute target is below the shell' if needed.negative?

        per = 64
        full, rest = needed.divmod(per)
        body = element_feed_open
        if full.positive?
          packed = %(<e #{per.times.map { |index| %(a#{index}="v") }.join(' ')}/>)
          body << (packed * full)
        end
        if rest.positive?
          body << %(<e #{rest.times.map { |index| %(a#{index}="v") }.join(' ')}/>)
        end
        body << '</channel></rss>'
        body
      end

      def element_feed_open
        body = +%(<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>Synthetic</title><link>https://feeds.example/synthetic</link><description>Generated.</description>\n)
        40.times { |index| body << plain_item(index) }
        body
      end

      def plain_item(index)
        number = format('%04d', index + 1)
        %(<item><title>Synthetic note #{number}</title><link>https://articles.example/notes/#{number}</link><guid>synthetic-#{number}</guid><description>Note</description></item>)
      end
    end
  end
end
