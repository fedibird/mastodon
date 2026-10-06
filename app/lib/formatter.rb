# frozen_string_literal: true

require 'singleton'

class Formatter
  include Singleton
  include RoutingHelper

  include ActionView::Helpers::TextHelper
  include StatusesHelper

  NEWLINE_TAGS_RE = %r{(<br />|<br>|</p>)+}
  CLOSING_PARAGRAPH_RE = %r{</p>\z}
  # PHP nl2br() inserts <br /> before a newline and keeps that newline.
  # After sanitize the tag is <br>, so one CRLF, LF+CR, CR, or LF sits
  # immediately after it. pre-wrap would draw both.
  BR_ADJACENT_NEWLINE_RE = %r{<br>(?:\r\n|\n\r|\r|\n)}.freeze

  # A decoded URL is only ever shown to a human or offered to a matcher, so any
  # Unicode control character in it is noise at best. It is also how the
  # KeywordSubscribe matching material separates its segments, so a decoded
  # control character must never reach it.
  UNDISPLAYABLE_URL_RE = /\p{Cc}/.freeze

  # blockquote, list, and pre stay closed. p and other structural tags are
  # not inline wrappers, but an empty one can still be trailing chrome.
  BLOCK_BOUNDARY_TAGS = %w(blockquote ul ol li pre).freeze
  VISIBLE_EMPTY_TAGS = %w(img video audio canvas svg iframe object embed picture hr input textarea button select).freeze
  STRUCTURAL_TAGS = %w(
    address article aside blockquote dd details div dl dt figcaption figure
    footer h1 h2 h3 h4 h5 h6 header li main nav ol p pre script section style
    summary table tbody td tfoot th thead tr ul
  ).freeze
  VISIBLE_EMPTY_SELECTOR = VISIBLE_EMPTY_TAGS.join(', ').freeze

  def format(status, **options)
    if status.reblog?
      prepend_reblog = status.reblog.account.acct
      status         = status.proper
    else
      prepend_reblog = false
    end

    raw_content = status.text

    if options[:inline_poll_options] && status.preloadable_poll
      raw_content = raw_content + "\n\n" + status.preloadable_poll.options.map { |title| "[ ] #{title}" }.join("\n")
    end

    if raw_content.blank?
      html = insert_status_suffixes('', attachment_and_reference_fragments(status))
      return html.html_safe # rubocop:disable Rails/OutputSafety
    end

    unless status.local?
      html = reformat(raw_content)
      html = strip_break_adjacent_newline(html)
      html = apply_inner_link(html, **options.merge(redirected_urls: redirected_urls(status)))
      html = apply_reference_link(html, status)
      html = encode_custom_emojis(html, status.emojis, options[:autoplay]) if options[:custom_emojify]
      html = nyaize_html(html) if options[:nyaize]
      html = apply_emoji_compatibility(html, status.emojis) if options[:emoji_compatibility]
      return html.html_safe # rubocop:disable Rails/OutputSafety
    end

    linkable_accounts = status.active_mentions.map(&:account)
    linkable_accounts << status.account

    html = raw_content
    html = "RT @#{prepend_reblog} #{html}" if prepend_reblog
    html = encode_and_link_urls(html, **options.merge(accounts: linkable_accounts, redirected_urls: redirected_urls(status)))
    html = encode_custom_emojis(html, status.emojis, options[:autoplay]) if options[:custom_emojify]
    html = simple_format(html, {}, sanitize: false)
    html = insert_status_suffixes(html, local_status_suffix_fragments(status, **options))
    html = nyaize_html(html) if options[:nyaize]
    html = html.delete("\n")
    html = apply_emoji_compatibility(html, status.emojis) if options[:emoji_compatibility]

    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def format_in_quote(status, **options)
    html = format(status)
    return '' if html.empty?
    doc = Nokogiri::HTML.parse(html, nil, 'utf-8')
    html = doc.css('body')[0].inner_html
    html.sub!(/^<p>(.+)<\/p>$/, '\1')
    html = Sanitize.clean(html).delete("\n").truncate(150)
    html = encode_custom_emojis(html, status.emojis) if options[:custom_emojify]
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def reformat(html)
    sanitize(html, Sanitize::Config::MASTODON_STRICT)
  rescue ArgumentError
    ''
  end

  def plaintext(status)
    return status.text if status.local?

    text = remove_reference_link(status.text)
    node = Nokogiri::HTML.fragment(text.gsub(NEWLINE_TAGS_RE) { |match| "#{match}\n" })
    # Elements that are entirely removed with our Sanitize config
    node.xpath('.//iframe|.//math|.//noembed|.//noframes|.//noscript|.//plaintext|.//script|.//style|.//svg|.//xmp').remove
    node.text.chomp
  end

  def simplified_format(account, **options)
    html = account.local? ? linkify(account.note, **options) : apply_inner_link(reformat(account.note), **options)
    html = encode_custom_emojis(html, account.emojis, options[:autoplay]) if options[:custom_emojify]
    html = apply_emoji_compatibility(html, account.emojis) if options[:emoji_compatibility]
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def format_message(account, message, **options)
    html = linkify(message, **options)
    html = encode_custom_emojis(html, account.emojis, options[:autoplay]) if options[:custom_emojify]
    html = apply_emoji_compatibility(html, account.emojis) if options[:emoji_compatibility]
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def sanitize(html, config)
    Sanitize.fragment(html, config)
  end

  def format_spoiler(status, **options)
    html = encode(status.spoiler_text)
    html = encode_custom_emojis(html, status.emojis, options[:autoplay])
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def format_poll_option(status, option, **options)
    html = encode(option.title)
    html = encode_custom_emojis(html, status.emojis, options[:autoplay])
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def format_display_name(account, **options)
    html = encode(account.display_name.presence || account.username)
    html = encode_custom_emojis(html, account.emojis, options[:autoplay]) if options[:custom_emojify]
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def format_field(account, str, **options)
    html = account.local? ? encode_and_link_urls(str, **options.merge(me: true, with_domain: true)) : apply_inner_link(reformat(str), **options)
    html = encode_custom_emojis(html, account.emojis, options[:autoplay]) if options[:custom_emojify]
    html = apply_emoji_compatibility(html, account.emojis) if options[:emoji_compatibility]
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  # custom_emojify replaces shortcodes with images for Fedibird's own HTML
  # and does not insert U+200B. emoji_compatibility leaves the shortcodes in
  # place and inserts U+200B where a recognized shortcode touches
  # non-whitespace text, so Mastodon-compatible consumers can still recognize
  # it. Edit/source responses must not request this. Only text nodes are
  # rewritten; href, src, and other attributes stay canonical.
  def apply_emoji_compatibility(html, emojis)
    return html if html.blank? || emojis.blank? || !html.include?(':')

    tree = Nokogiri::HTML.fragment(html)
    changed = false

    tree.xpath('./text()|.//text()[not(ancestor[@class="invisible"])]').each do |node|
      converted = CustomEmoji.with_compatible_boundaries(node.content, emojis)
      next if converted == node.content

      node.content = converted
      changed = true
    end

    # HTMLEntities leaves an all-ASCII string tagged US-ASCII, and Nokogiri then
    # serializes U+200B as &#8203;. Force UTF-8 so the raw character is returned.
    changed ? tree.to_html(encoding: 'UTF-8') : html
  end

  def format_summary(emoji)
    val = []
    val << "name: #{emoji.alternate_name}" if emoji.alternate_name.present?
    val << "(#{emoji.ruby})" if emoji.ruby.present?
    val << "creator: #{emoji.creator}" if emoji.creator.present?
    val << "copyrightNotice: #{emoji.copyright_notice}" if emoji.copyright_notice.present?
    val << "creditText: #{emoji.credit_text}" if emoji.credit_text.present?
    val << "license: #{emoji.license_name.presence || emoji.license}" if emoji.license.present?
    val << "usage: #{emoji.usage_info}" if emoji.usage_info.present?
    val << "links: #{emoji.related_link}" if emoji.related_link.present?
    val << "##{emoji.copy_permission.to_s}" unless emoji.none_permission?
    val << "description: #{emoji.description}" if emoji.description.present?
    val.compact.join(', ').gsub!(/\r\n|\r|\n/, ' ')
  end

  def format_bridgy_fed(text, url, **options)
    text = text.chomp("")
    return if text.blank?

    text = "[CW] #{text}"
    html = encode_and_link_urls(text, **options)
    html = simple_format(html, {}, sanitize: false)
    link = "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"unhandled-link\">[Read the full article]</a>"
    html.sub!(/^<p>/, "<p><span class=\"original-post-link\">#{link}</span><br><br>")

    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def linkify(text, **options)
    html = encode_and_link_urls(text, **options)
    html = simple_format(html, {}, sanitize: false)
    html = html.delete("\n")

    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def add_original_link_from_status(html, status)
    insert_status_suffixes(html, [original_media_link_html(status)])
  end

  # Written into stored remote status text during ingest. Not a display-time
  # suffix, so trailing-hashtag placement does not apply.
  def add_original_link(html, url, summary)
    html = '<p></p>' if html.blank?
    html.sub(/<\/p>\z/, " <a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"unhandled-link\">[#{summary}]</a></p>")
  end

  def extract_inner_link(status)
    Nokogiri::HTML.parse(format(status), nil, 'utf-8').css('a:not(.mention):not(.unhandled-link)').map { |x| x['href'].presence }.compact.uniq
  end

  # The human-readable representation of one URL: the form link text shows, and
  # the form filters and keyword subscriptions match against besides the
  # canonical one. It is never URL identity, so it must not be used as an href,
  # stored, or fetched.
  #
  # Percent sequences are decoded exactly once, so `%252F` reads as `%2F` rather
  # than as a slash. A decoded URL that is not valid UTF-8, or that carries a
  # control character, is refused and the canonical form is returned as is. This
  # never raises.
  def display_url(url)
    canonical = url.to_s

    decode_url_once(canonical) || canonical
  end

  def remove_compatible_object_link(html)
    # <p>...<span>...<br><br>RE: </span><a href=\"https://misskey.io/notes/xxxxxxxxxxxxxxxx\">https://misskey.io/notes/xxxxxxxxxxxxxxxx</a></p>

    tree     = Nokogiri::HTML.fragment(html)
    children = tree.children.size == 1 ? tree.child.children : tree.children

    if children.size >= 2
      anchor   = children.pop
      prefix   = children.last.class.name == 'Nokogiri::XML::Text' ? children.last : children.last.children.last

      if anchor.name == 'a' && prefix.class.name == 'Nokogiri::XML::Text' && prefix.content == 'RE: '
        if children.last.class.name == 'Nokogiri::XML::Text'
          children.pop
          children.pop if children.last&.name == 'br'
          children.pop if children.last&.name == 'br'
        else
          children.last.children = children.last.children.then do |children|
            children.pop
            children.pop if children.last&.name == 'br'
            children.pop if children.last&.name == 'br'
            children
          end
          children.pop if children.last.children.size == 0
        end

        if tree.children.size == 1
          tree.child.children = children
        else
          tree.children = children
        end  
      end

      tree.to_html.html_safe
    else
      html.html_safe
    end
  end

  private

  def strip_break_adjacent_newline(html)
    html.gsub(BR_ADJACENT_NEWLINE_RE, '<br>')
  end

  def redirected_urls(status)
    status.preview_cards.map { |preview_card| [preview_card.url, preview_card.redirected_url] if preview_card.redirected_url }.compact.to_h
  end

  def html_entities
    @html_entities ||= HTMLEntities.new
  end

  def encode(html)
    html_entities.encode(html)
  end

  def encode_and_link_urls(html, **options)
    entities = utf8_friendly_extractor(html, extract_url_without_protocol: false)

    rewrite(html.dup, entities) do |entity|
      if entity[:url]
        link_to_url(entity, **options)
      elsif entity[:hashtag]
        link_to_hashtag(entity)
      elsif entity[:screen_name]
        link_to_mention(entity, options[:accounts], **options)
      end
    end
  end

  def count_tag_nesting(tag)
    if tag[1] == '/' then -1
    elsif tag[-2] == '/' then 0
    else 1
    end
  end

  # Known :shortcode: values are replaced regardless of the surrounding
  # characters. See CustomEmoji::SCAN_RE. Fedibird's own HTML does not insert
  # U+200B; the image replaces the shortcode directly.
  # rubocop:disable Metrics/BlockNesting
  def encode_custom_emojis(html, emojis, animate = false)
    return html if emojis.empty?

    emoji_map = emojis.each_with_object({}) { |e, h| h[e.shortcode] = [full_asset_url(e.image.url), full_asset_url(e.image.url(:static))] }

    tree = Nokogiri::HTML.fragment(html)
    tree.xpath('./text()|.//text()[not(ancestor[@class="invisible"])]').to_a.each do |node|
      i                     = -1
      inside_shortname      = false
      shortname_start_index = -1
      last_index            = 0
      text                  = node.content
      result                = Nokogiri::XML::NodeSet.new(tree.document)

      while i + 1 < text.size
        i += 1

        if inside_shortname && text[i] == ':'
          inside_shortname = false
          shortcode = text[shortname_start_index + 1..i - 1]

          next unless (emoji = emoji_map[shortcode])

          original_url, static_url = emoji

          result << Nokogiri::XML::Text.new(text[last_index..shortname_start_index - 1], tree.document) if shortname_start_index.positive?

          result << Nokogiri::HTML.fragment(
            if animate
              image_tag(original_url, draggable: false, class: 'emojione', alt: ":#{shortcode}:", title: ":#{shortcode}:")
            else
              image_tag(original_url, draggable: false, class: 'emojione custom-emoji', alt: ":#{shortcode}:", title: ":#{shortcode}:", data: { original: original_url, static: static_url })
            end
          )

          last_index = i + 1
        elsif text[i] == ':'
          inside_shortname = true
          shortname_start_index = i
        end
      end

      result << Nokogiri::XML::Text.new(text[last_index..-1], tree.document)
      node.replace(result)
    end

    tree.to_html
  end
  # rubocop:enable Metrics/BlockNesting

  def quotify(html, status, **options)
    return html if html.blank?

    insert_status_suffixes(html, [quote_inline_html(status, **options)])
  end

  def add_compatible_reference_link(html, status)
    insert_status_suffixes(html, [compatible_reference_link_html(status)])
  end

  # Place every display-time suffix before a trailing hashtag block.
  # The status HTML is parsed once. With no trailing hashtags, the fragments
  # are appended before the final </p> without reserializing the rest.
  def insert_status_suffixes(html, fragments)
    fragments = Array(fragments).map(&:to_s).reject(&:blank?)
    return html if fragments.empty?

    html = html.to_s
    html = '<p></p>' if html.blank?
    return append_status_suffixes(html, fragments) unless html.include?('hashtag')

    parsed = Nokogiri::HTML.fragment(html)
    point = trailing_hashtag_insertion_point(parsed)
    return append_status_suffixes(html, fragments) if point.nil?

    inserted = Nokogiri::HTML.fragment(fragments.join).children.to_a
    insert_nodes_at(point, inserted)
    parsed.to_html(encoding: 'UTF-8')
  end

  def local_status_suffix_fragments(status, **options)
    fragments = []
    fragments << quote_inline_html(status, **options) if status.quote? && !options[:escape_quotify]
    fragments.concat(attachment_and_reference_fragments(status))
  end

  def attachment_and_reference_fragments(status)
    fragments = []
    fragments << original_media_link_html(status) if status.media_attachments.count > 4
    fragments << compatible_reference_link_html(status) if status.references.exists?
    fragments
  end

  def quote_inline_html(status, **options)
    url = ActivityPub::TagManager.instance.url_for(status.quote)
    link = encode_and_link_urls(url, **options)
    "<span class=\"quote-inline\"><br/>QT: #{link}</span>"
  end

  def original_media_link_html(status)
    url = ActivityPub::TagManager.instance.url_for(status)
    summary = media_summary(status)
    link = "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"unhandled-link\">[#{summary}]</a>"
    "<span class=\"original-media-link\"> #{link}</span>"
  end

  def compatible_reference_link_html(status)
    url = references_short_account_status_url(status.account, status)
    link = "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"status-link unhandled-link\" data-status-id=\"#{status.id}\">#{I18n.t('status_references.link_text')}</a>"
    "<span class=\"reference-link-inline\"> #{link}</span>"
  end

  def append_status_suffixes(html, fragments)
    html.sub(CLOSING_PARAGRAPH_RE, "#{fragments.join}</p>")
  end

  # [:before, node] inserts in front of the hashtag row, including the <br>
  # that separates it from the body. [:append, element] keeps a hashtag-only
  # final paragraph where it is and puts the suffix on the previous paragraph.
  def trailing_hashtag_insertion_point(root)
    container = trailing_content_container(root)
    return if container.nil?

    scan = scan_trailing_hashtags(container.children.to_a)
    return if scan.nil?

    if scan[:index].negative?
      previous = appendable_previous_block(container)
      return [:append, previous] if previous
    end

    nodes = scan[:nodes]
    boundary = scan[:separator_br_index] || scan[:first_hashtag_index]
    [:before, nodes[boundary]]
  end

  # Only the final top-level paragraph is a trailing-hashtag container.
  # blockquote, list, and pre stay closed so a generated link cannot look
  # like part of quoted or preformatted text.
  def trailing_content_container(root)
    last = last_content_child(root)
    last&.element? && last.name == 'p' ? last : root
  end

  def last_content_child(node)
    child = node.children.last
    child = child.previous while child && (ignorable_node?(child) || line_break?(child))
    child
  end

  def scan_trailing_hashtags(nodes)
    index = nodes.length - 1
    seen_hashtag = false
    first_hashtag_index = nil
    separator_br_index = nil

    while index >= 0
      node = nodes[index]

      if ignorable_node?(node) || (!seen_hashtag && line_break?(node))
        index -= 1
        next
      end

      if trailing_hashtag_group?(node)
        seen_hashtag = true
        first_hashtag_index = index
        index -= 1
        next
      end

      break unless seen_hashtag && line_break?(node)

      relation = break_relation(nodes, index)
      separator_br_index = index unless relation == :internal
      break if relation == :content

      index -= 1
    end

    return unless seen_hashtag

    { index: index, nodes: nodes, first_hashtag_index: first_hashtag_index, separator_br_index: separator_br_index }
  end

  def break_relation(nodes, index)
    previous = previous_significant_index(nodes, index)
    return :leading if previous.nil?

    previous_node = nodes[previous]
    return :internal if trailing_hashtag_group?(previous_node)
    return :break_run if line_break?(previous_node)

    :content
  end

  def previous_significant_index(nodes, index)
    cursor = index - 1
    cursor -= 1 while cursor >= 0 && ignorable_node?(nodes[cursor])
    cursor >= 0 ? cursor : nil
  end

  def appendable_previous_block(container)
    return unless container.element? && container.name == 'p'

    previous = container.previous_element
    previous if previous&.name == 'p'
  end

  # Local anchors match a.mention.hashtag[rel~="tag"]. Remote reformat keeps
  # those classes, but Sanitize's add_attributes replaces rel="tag" with
  # "nofollow noopener noreferrer", so rel is not required here.
  def trailing_hashtag_anchor?(node)
    return false unless node.element? && node.name == 'a'

    classes = node['class'].to_s.split(/[\t\n\f\r ]/)
    classes.include?('mention') && classes.include?('hashtag')
  end

  # A hashtag anchor, or an inline wrapper whose visible content is only a
  # hashtag run. The wrapper is one group, so a suffix is inserted before
  # the element rather than inside it.
  def trailing_hashtag_group?(node)
    trailing_hashtag_anchor?(node) || trailing_hashtag_wrapper?(node)
  end

  def trailing_hashtag_wrapper?(node)
    return false unless inline_hashtag_wrapper_element?(node)

    hashtag = false

    node.children.each do |child|
      kind = hashtag_run_child(child)
      return false if kind == :content

      hashtag = true if kind == :hashtag
    end

    hashtag
  end

  def hashtag_run_child(node)
    return :chrome if hashtag_run_chrome?(node)
    return :hashtag if trailing_hashtag_anchor?(node) || trailing_hashtag_wrapper?(node)

    :content
  end

  def hashtag_run_chrome?(node)
    ignorable_node?(node) || line_break?(node) || displayless_element?(node)
  end

  def inline_hashtag_wrapper_element?(node)
    node.element? && node.name != 'a' && node.name != 'br' && !STRUCTURAL_TAGS.include?(node.name) && !VISIBLE_EMPTY_TAGS.include?(node.name)
  end

  def displayless_element?(node)
    return false unless node.element?
    return false if BLOCK_BOUNDARY_TAGS.include?(node.name) || VISIBLE_EMPTY_TAGS.include?(node.name)
    return false if node.inner_text.match?(/\S/)

    node.css(VISIBLE_EMPTY_SELECTOR).empty?
  end

  def ignorable_node?(node)
    return true if node.comment?

    node.text? && node.content.match?(/\A[[:space:]]*\z/)
  end

  def line_break?(node)
    node.element? && node.name == 'br'
  end

  def insert_nodes_at(point, nodes)
    nodes = Array(nodes).compact
    return if nodes.empty?

    mode, target = point
    if mode == :append
      nodes.each { |node| target.add_child(node) }
    else
      nodes.each { |node| target.add_previous_sibling(node) }
      ensure_space_before_hashtag(target)
    end
  end

  def ensure_space_before_hashtag(node)
    return unless trailing_hashtag_group?(node)

    previous = node.previous
    return if previous&.text? && previous.content.match?(/[[:space:]]\z/)

    node.add_previous_sibling(Nokogiri::XML::Text.new(' ', node.document))
  end

  def detach_reference_link(doc)
    node = doc.at_css('span.reference-link-inline')
    return if node.blank?

    url = node.at_css('a')&.attr('href').to_s.scrub
    node.unlink
    url
  end

  def insert_remote_reference_link(doc, url, status)
    body = doc.at_css('body')
    return if body.nil?

    ref_span = reference_link_node(doc, url, status)
    point = trailing_hashtag_insertion_point(body)
    if point
      insert_nodes_at(point, [ref_span])
    else
      (doc.at_css('body > p:last-child') || body).add_child(ref_span)
    end
  end

  def reference_link_node(doc, url, status)
    ref_span = Nokogiri::XML::Node.new('span', doc)
    ref_anchor = Nokogiri::XML::Node.new('a', doc)
    ref_anchor.add_class('status-link unhandled-link')
    ref_anchor['href'] = url
    ref_anchor['target'] = '_blank'
    ref_anchor['rel'] = 'noopener noreferrer'
    ref_anchor['data-status-id'] = status.id
    ref_anchor.content = I18n.t('status_references.link_text')
    ref_span.content = ' '
    ref_span.add_class('reference-link-inline')
    ref_span.add_child(ref_anchor)
    ref_span
  end

  def nyaize_html(html)
    inside_anchor = false

    html.split(/(<.+?>)/).compact.map do |x|
      if x.match(/^<a/)
        inside_anchor = true
      elsif x == '</a>'
        inside_anchor = false
      end

      if inside_anchor || x[0] == '<'
        x
      else
        x.split(/(:.+?:)/).compact.map do |x|
          if x[0] == ':'
            x
          else
            nyaize(x)
          end
        end.join
      end
    end.join
  end

  def nyaize(text)
    text
      # ja-JP
      .gsub(/な/, "にゃ").gsub(/ナ/, "ニャ").gsub(/ﾅ/, "ﾆｬ")
      # en-US
      .gsub(/(?<=n)a/i) { |x| x == 'A' ? 'YA' : 'ya' }
      .gsub(/(?<=morn)ing/i) { |x| x == 'ING' ? 'YAN' : 'yan' }
      .gsub(/(?<=every)one/i) { |x| x == 'ONE' ? 'NYAN' : 'nyan' }
      # vko-KR
      .gsub(/[나-낳]/) { |c| (c.ord + '냐'.ord - '나'.ord).chr }
      .gsub(/(다)|(다(?=\.))|(다(?= ))|(다(?=!))|(다(?=\?))/m, '다냥')
      .gsub(/(야(?=\?))|(야$)|(야(?= ))/m, '냥')
  end

  def rewrite(text, entities)
    text = text.to_s

    # Sort by start index
    entities = entities.sort_by do |entity|
      indices = entity.respond_to?(:indices) ? entity.indices : entity[:indices]
      indices.first
    end

    result = []

    last_index = entities.reduce(0) do |index, entity|
      indices = entity.respond_to?(:indices) ? entity.indices : entity[:indices]
      result << encode(text[index...indices.first])
      result << yield(entity)
      indices.last
    end

    result << encode(text[last_index..-1])

    result.flatten.join
  end

  def utf8_friendly_extractor(text, **options)
    # Note: I couldn't obtain list_slug with @user/list-name format
    # for mention so this requires additional check
    special = Extractor.extract_urls_with_indices(text, options)
    standard = Extractor.extract_entities_with_indices(text, options)
    extra = Extractor.extract_extra_uris_with_indices(text, options)

    Extractor.remove_overlapping_entities(special + standard + extra)
  end

  def class_append(c, items)
    (c || '').split.concat(items).uniq.join(' ')
  end

  def link_to_url(entity, **options)
    entity_url = entity[:url]
    url        = Addressable::URI.parse(entity_url).normalize.to_s
    html_attrs = { target: '_blank', rel: 'nofollow noopener noreferrer' }

    html_attrs[:rel] = "me #{html_attrs[:rel]}" if options[:me]

    status, path  = url_to_holding_status(url)
    account       = status&.account
    account, path = url_to_holding_account(url) if status.nil?
    account       = account.moved_to_account if account&.moved?

    emoji = nil
    if TagManager.instance.local_url?(url)
      (Rails.application.routes.recognize_path(url) rescue {}).tap do |recognized_params|
        if recognized_params[:action] == 'show' && recognized_params[:controller] == 'emojis'
          emoji = CustomEmoji.find_by(shortcode: recognized_params[:id], domain: nil)
        end
      end
    else
      emoji = CustomEmoji.find_by(uri: url)
    end

    if emoji.present?
      html_attrs[:class]            = class_append(html_attrs[:class], ['custom-emoji-url-link'])
      html_attrs[:'data-shortcode'] = emoji.shortcode
      html_attrs[:'data-domain']    = emoji.domain if emoji.domain.present?
    elsif status.present? && account.present?
      html_attrs[:class]                      = class_append(html_attrs[:class], ['status-url-link'])
      html_attrs[:'data-status-id']           = status.id
      html_attrs[:'data-status-account-acct'] = account.acct
      html_attrs[:'data-path']                = path
    elsif account.present?
      html_attrs[:class]                     = class_append(html_attrs[:class], ['account-url-link'])
      html_attrs[:'data-account-id']         = account.id
      html_attrs[:'data-account-actor-type'] = account.actor_type
      html_attrs[:'data-account-acct']       = account.acct
      html_attrs[:'data-path']               = path
    elsif options[:redirected_urls]&.key?(url)
      entity_url = url = options[:redirected_urls][url]
    elsif (redirect_link = RedirectLink.find_by(url: url))
      entity_url = url = redirect_link.redirected_url
    elsif (options[:rest] && FetchLinkCardService.redirect_target_host?(Addressable::URI.parse(url).host))
      return encode(entity[:url])
    end

    Twitter::TwitterText::Autolink.send(:link_to_text, entity, link_html(entity_url), url, html_attrs)
  rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
    encode(entity[:url])
  end

  def apply_inner_link(html, **options)
    doc = Nokogiri::HTML.parse(html, nil, 'utf-8')
    doc.css('a').each do |x|
      begin
        href = Addressable::URI.parse(x['href']).normalize.to_s
      rescue ArgumentError, Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
        next
      end

      status, path  = url_to_holding_status(href)
      account       = status&.account
      account, path = url_to_holding_account(href) if status.nil?
      account       = account.moved_to_account if account&.moved?

      emoji = nil
      if TagManager.instance.local_url?(href)
        (Rails.application.routes.recognize_path(href) rescue {}).tap do |recognized_params|
          if recognized_params[:action] == 'show' && recognized_params[:controller] == 'emojis'
            emoji = CustomEmoji.find_by(shortcode: recognized_params[:id], domain: nil)
          end
        end
      else
        emoji = CustomEmoji.find_by(uri: href) if status.nil? && account.nil?
      end

      if emoji.present?
        x.add_class('custom-emoji-url-link')
        x['data-shortcode']      = emoji.shortcode
        x['data-domain']         = emoji.domain if emoji.domain.present?
      elsif status.present? && account.present?
        x.add_class('status-url-link')
        x['data-status-id']           = status.id
        x['data-status-account-acct'] = account.acct
        x['data-path']                = path
      elsif account.present?
        x.add_class('account-url-link')
        x['data-account-id']         = account.id
        x['data-account-actor-type'] = account.actor_type
        x['data-account-acct']       = account.acct
        x['data-path']               = path
      elsif options[:redirected_urls]&.key?(href)
        x['href']    = options[:redirected_urls][href]
        x.inner_html = link_html(href) if x.text.start_with?('https://')
      elsif (redirect_link = RedirectLink.find_by(url: href))
        x['href']    = redirect_link.redirected_url
        x.inner_html = link_html(href) if x.text.start_with?('https://')
      elsif (
        begin 
          options[:rest] && FetchLinkCardService.redirect_target_host?(Addressable::URI.parse(href).host)
        rescue Addressable::URI::InvalidURIError
          true
        end
        )
        x.replace(x.children)
      end
    end
    html = doc.css('body')[0]&.inner_html || ''
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def remove_reference_link(html)
    doc = Nokogiri::HTML.parse(html, nil, 'utf-8')
    doc.at_css('span.reference-link-inline')&.unlink 
    html = doc.at_css('body')&.inner_html || ''
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def apply_reference_link(html, status)
    doc = Nokogiri::HTML.parse(html, nil, 'utf-8')
    reference_link_url = detach_reference_link(doc)

    if status.references.exists?
      insert_remote_reference_link(doc, reference_link_url || status.url, status)
    end

    html = doc.at_css('body')&.inner_html || ''
    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  def normalize_url_without_fragment(url)
    return if url.nil?

    uri = Addressable::URI.parse(url).normalize
    uri.fragment = nil
    uri.to_s
  rescue
    nil
  end

  def url_to_holding_account(url)
    url = normalize_url_without_fragment(url)

    return if url.nil?

    account_url, path = url.match(%r{^(.+)(/tagged/[^/]+|/with_replies|/media|/following|/followers).*$}).to_a.values_at(1,2)

    url  = account_url if account_url.present?
    path = "/posts#{path.delete_prefix('/tagged')}" if path&.start_with?('/tagged')

    [EntityCache.instance.holding_account(url), path]
  end

  def url_to_holding_status(url)
    url = normalize_url_without_fragment(url)

    return if url.nil?

    if url.end_with?('/references')
      path = '/references'
      url.delete_suffix!(path)
    end

    [EntityCache.instance.holding_status(url), path]
  end

  def link_to_mention(entity, linkable_accounts, **options)
    acct = entity[:screen_name]

    return link_to_account(acct, **options) unless linkable_accounts

    same_username_hits = 0
    account = nil
    username, domain = acct.split('@')
    domain = nil if TagManager.instance.local_domain?(domain)

    linkable_accounts.each do |item|
      same_username = item.username.casecmp(username).zero?
      same_domain   = item.domain.nil? ? domain.nil? : item.domain.casecmp(domain)&.zero?

      if same_username && !same_domain
        same_username_hits += 1
      elsif same_username && same_domain
        account = item
      end
    end

    account ? mention_html(account, with_domain: same_username_hits.positive? || options[:with_domain]) : "@#{encode(acct)}"
  end

  def link_to_account(acct, **options)
    username, domain = acct.split('@')

    domain  = nil if TagManager.instance.local_domain?(domain)
    account = EntityCache.instance.mention(username, domain)

    account ? mention_html(account, with_domain: options[:with_domain]) : "@#{encode(acct)}"
  end

  def link_to_hashtag(entity)
    hashtag_html(entity[:hashtag])
  end

  # Returns nil rather than a decoded URL when the URL cannot be parsed, when
  # decoding it produces bytes that are not valid UTF-8, or when it produces a
  # control character.
  #
  # Addressable raises InvalidURIError for a URL it cannot parse or reassemble,
  # and ArgumentError when the given String itself is not valid UTF-8, which is
  # possible for text that arrived from a remote instance.
  def decode_url_once(url)
    decoded = Addressable::URI.unencode(Addressable::URI.parse(url).to_s)

    # Addressable tags its result UTF-8, but the bytes a percent sequence
    # produces are arbitrary, so the result still has to be checked.
    decoded = decoded.dup.force_encoding(Encoding::UTF_8) unless decoded.encoding == Encoding::UTF_8

    return if !decoded.valid_encoding? || decoded.match?(UNDISPLAYABLE_URL_RE)

    decoded
  rescue Addressable::URI::InvalidURIError, ArgumentError
    nil
  end

  def link_html(url)
    url    = display_url(url)
    prefix = url.match(/\A(https?:\/\/(www\.)?|xmpp:)/).to_s
    text   = url[prefix.length, 30]
    suffix = url[prefix.length + 30..-1]
    cutoff = url[prefix.length..-1].length > 30

    "<span class=\"invisible\">#{encode(prefix)}</span><span class=\"#{cutoff ? 'ellipsis' : ''}\">#{encode(text)}</span><span class=\"invisible\">#{encode(suffix)}</span>"
  end

  def hashtag_html(tag)
    "<a href=\"#{encode(tag_url(tag))}\" class=\"mention hashtag\" rel=\"tag\">#<span>#{encode(tag)}</span></a>"
  end

  def mention_html(account, with_domain: false)
    return if account.nil?

    url       = ActivityPub::TagManager.instance.url_for(account)
    link_text = with_domain ? account.pretty_acct : account.username
    account   = account.moved_to_account if account&.moved?

    return if account.nil?
    
    classes = "u-url mention account-url-link#{account.actor_type == 'Group' ? ' group' : ''}"

    <<~HTML.squish
      <span class="h-card" translate="no"><a href="#{encode(url)}" class="#{classes}" data-account-id="#{account.id}" data-account-actor-type="#{account.actor_type}" data-account-acct="#{account.acct}">@<span>#{encode(link_text)}</span></a></span>
    HTML
  end
end
