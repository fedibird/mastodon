# frozen_string_literal: true

class TranslateStatusService < BaseService
  CACHE_TTL = 1.day.freeze

  include ERB::Util

  def call(status, target_language)
    @status = status
    @source_texts = source_texts
    @target_language = target_language

    raise Mastodon::NotPermittedError unless permitted?

    status_translation = Rails.cache.fetch("v2:translations/#{@status.language}/#{@target_language}/#{content_hash}", expires_in: CACHE_TTL) do
      translations = translation_backend.translate(@source_texts.values, @status.language, @target_language)
      build_status_translation(translations)
    end

    status_translation.status = @status

    status_translation
  end

  private

  def translation_backend
    @translation_backend ||= TranslationService.configured
  end

  def permitted?
    return false unless @status.distributable? && TranslationService.configured?

    languages[@status.language]&.include?(@target_language)
  end

  def languages
    Rails.cache.fetch('translation_service/languages', expires_in: 7.days, race_condition_ttl: 1.hour) { TranslationService.configured.languages }
  end

  def content_hash
    Digest::SHA256.base64digest(@source_texts.transform_keys { |key| key.respond_to?(:id) ? "#{key.class}-#{key.id}" : key }.to_json)
  end

  def source_texts
    texts = {}
    texts[:content] = wrap_emoji_shortcodes(status_content_format(@status), @status.proper.emojis) if @status.content.present?
    texts[:spoiler_text] = wrap_emoji_shortcodes(html_escape(@status.spoiler_text)) if @status.spoiler_text.present?

    @status.preloadable_poll&.loaded_options&.each do |option|
      texts[option] = wrap_emoji_shortcodes(html_escape(option.title))
    end

    @status.media_attachments.each do |media_attachment|
      texts[media_attachment] = html_escape(media_attachment.description)
    end

    texts
  end

  # Match REST::StatusSerializer#content so translation source HTML uses the
  # same redirect-target handling as the status the client already sees.
  def status_content_format(status)
    Formatter.instance.format(status, rest: true, emoji_compatibility: true)
  end

  def build_status_translation(translations)
    status_translation = Translation.new(
      detected_source_language: translations.first&.detected_source_language,
      language: @target_language,
      provider: translations.first&.provider,
      content: '',
      spoiler_text: '',
      poll_options: [],
      media_attachments: []
    )

    @source_texts.keys.each_with_index do |source, index|
      translation = translations[index]

      case source
      when :content
        node = unwrap_emoji_shortcodes(translation.text)
        Sanitize.node!(node, Sanitize::Config::MASTODON_STRICT)
        status_translation.content = Formatter.instance.apply_emoji_compatibility(node.to_html, @status.proper.emojis)
      when :spoiler_text
        status_translation.spoiler_text = CustomEmoji.with_compatible_boundaries(unwrap_emoji_shortcodes(translation.text).content, @status.emojis)
      when Poll::Option
        status_translation.poll_options << Translation::Option.new(
          title: CustomEmoji.with_compatible_boundaries(unwrap_emoji_shortcodes(translation.text).content, @status.emojis)
        )
      when MediaAttachment
        status_translation.media_attachments << Translation::MediaAttachment.new(
          id: source.id,
          description: html_entities.decode(translation.text)
        )
      end
    end

    status_translation
  end

  # Walk text nodes only. A whole-string gsub would rewrite :shortcode: inside
  # href and other attributes and break the HTML Formatter already produced.
  def wrap_emoji_shortcodes(html, emojis = @status.emojis)
    html = html.to_s
    return html if emojis.empty?

    shortcodes = emojis.each_with_object({}) { |emoji, map| map[emoji.shortcode] = true }
    tree = Nokogiri::HTML.fragment(html)
    tree.xpath('./text()|.//text()[not(ancestor[@class="invisible"])]').to_a.each do |node|
      i = -1
      inside_shortname = false
      shortname_start_index = -1
      last_index = 0
      text = node.content
      result = Nokogiri::XML::NodeSet.new(tree.document)

      while i + 1 < text.size
        i += 1

        if inside_shortname && text[i] == ':'
          inside_shortname = false
          shortcode = text[shortname_start_index + 1..i - 1]

          # Same recognition rule as CustomEmoji::SCAN_RE: a known shortcode
          # is wrapped even when it touches letters, Japanese, or punctuation.
          next unless shortcodes[shortcode]

          result << Nokogiri::XML::Text.new(text[last_index..shortname_start_index - 1], tree.document) if shortname_start_index.positive?

          span = Nokogiri::XML::Node.new('span', tree.document)
          span['translate'] = 'no'
          span.content = ":#{shortcode}:"
          result << span

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

  def unwrap_emoji_shortcodes(html)
    fragment = Nokogiri::HTML.fragment(html)
    fragment.css('span[translate="no"]').each do |element|
      element.remove_attribute('translate')
      element.replace(element.children) if element.attributes.empty?
    end
    fragment
  end

  def html_entities
    HTMLEntities.new
  end
end
