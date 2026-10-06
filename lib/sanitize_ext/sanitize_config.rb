# frozen_string_literal: true

class Sanitize
  module Config
    HTTP_PROTOCOLS = %w(
      http
      https
    ).freeze

    LINK_PROTOCOLS = %w(
      http
      https
      dat
      dweb
      ipfs
      ipns
      ssb
      gopher
      xmpp
      magnet
      gemini
    ).freeze

    # Misskey sends <a href="..." rel="tag">#name</a>. Pixelfed sends
    # <a class="u-url hashtag" rel="external nofollow noopener">#name</a>.
    # Custom transformers run before add_attributes replaces rel, so a tag
    # token is still visible here. title is not a signal: MASTODON_STRICT
    # drops it. Existing classes are kept and not repeated.
    HASHTAG_ANCHOR_CLASS_TRANSFORMER = lambda do |env|
      return unless env[:node_name] == 'a'

      node = env[:node]
      text = node.inner_text.lstrip
      return unless text.start_with?('#') || text.start_with?('＃')

      rel_tokens = node['rel'].to_s.split(/[\t\n\f\r ]/)
      classes = node['class'].to_s.split(/[\t\n\f\r ]/).reject(&:empty?)
      return unless rel_tokens.include?('tag') || classes.include?('hashtag')

      classes << 'mention' unless classes.include?('mention')
      classes << 'hashtag' unless classes.include?('hashtag')
      node['class'] = classes.join(' ')
    end

    CLASS_WHITELIST_TRANSFORMER = lambda do |env|
      node = env[:node]
      class_list = node['class']&.split(/[\t\n\f\r ]/)

      return unless class_list

      class_list.keep_if do |e|
        next true if /^(h|p|u|dt|e)-/.match?(e) # microformats classes
        next true if /^(mention|hashtag)$/.match?(e) # semantic classes
        next true if /^(ellipsis|invisible)$/.match?(e) # link formatting classes
        next true if /^quote-inline$/.match?(e) # quote inline classes
        next true if /^reference-link-inline$/.match?(e) # reference link inline classes
        next true if /^original-media-link$/.match?(e) # original media link classes
      end

      node['class'] = class_list.join(' ')
    end

    UNSUPPORTED_HREF_TRANSFORMER = lambda do |env|
      return unless env[:node_name] == 'a'

      current_node = env[:node]

      scheme = begin
        if current_node['href'] =~ Sanitize::REGEX_PROTOCOL
          Regexp.last_match(1).downcase
        else
          :relative
        end
      end

      current_node.replace(current_node.text) unless LINK_PROTOCOLS.include?(scheme)
    end

    UNSUPPORTED_ELEMENTS_TRANSFORMER = lambda do |env|
      return unless %w(h1 h2 h3 h4 h5 h6).include?(env[:node_name])

      current_node = env[:node]

      current_node.name = 'strong'
      current_node.wrap('<p></p>')
    end

    # `small` stays so a Misskey trailing-hashtag group remains one inline
    # wrapper. Formatter then inserts compatibility suffixes before it.
    MASTODON_STRICT = freeze_config(
      elements: %w(p br span a del s pre blockquote code b strong u i em ul ol li ruby rt rp small),

      attributes: {
        'a'    => %w(href rel class),
        'span' => %w(class),
        'ol' => %w(start reversed),
        'li' => %w(value),
      },

      add_attributes: {
        'a' => {
          'rel' => 'nofollow noopener noreferrer',
          'target' => '_blank',
        },
      },

      protocols: {},

      transformers: [
        HASHTAG_ANCHOR_CLASS_TRANSFORMER,
        CLASS_WHITELIST_TRANSFORMER,
        UNSUPPORTED_ELEMENTS_TRANSFORMER,
        UNSUPPORTED_HREF_TRANSFORMER,
      ]
    )

    MASTODON_OEMBED = freeze_config(
      elements: %w(audio iframe source video),

      attributes: {
        'audio'  => %w(controls),
        'iframe' => %w(allowfullscreen frameborder height scrolling src width),
        'source' => %w(src type),
        'video'  => %w(controls height loop width),
      },

      protocols: {
        'iframe' => { 'src' => HTTP_PROTOCOLS },
        'source' => { 'src' => HTTP_PROTOCOLS },
      },

      add_attributes: {
        'iframe' => { 'sandbox' => 'allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms' },
      }
    )
  end
end
