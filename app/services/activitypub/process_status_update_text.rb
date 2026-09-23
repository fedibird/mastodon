# frozen_string_literal: true

# Create-compatible text normalization for remote status updates.
# ActivityPub::Parser::StatusParser stays identical to Mastodon v4.2.
# A quote compatibility link is removed only when it points at the quote
# this status already stores.
module ActivityPub::ProcessStatusUpdateText
  private

  def compatible_text
    @compatible_text ||= add_compatible_content(text_from_content || '')
  end

  def compatible_language
    @status_parser.language.presence || LanguageDetector.instance.detect(compatible_text, @account)
  end

  def text_from_content
    return Formatter.instance.remove_compatible_object_link(fedibird_content) if strip_compatible_quote_link?

    fedibird_content
  end

  def fedibird_content
    return @fedibird_content if defined?(@fedibird_content)

    content = raw_content.dup
    match = content.match(/QT:\s*\[<a href="([^"]+).*?\]/)
    content = content.sub(/QT:\s*\[.*?\]/, '<span class="quote-inline"><br/>\0</span>') if match && same_existing_quote?(match[1])
    @fedibird_content = content
  end

  def raw_content
    if @json['content'].present?
      @json['content']
    elsif content_language_map? && @json['contentMap'].values.first.present?
      @json['contentMap'].values.first
    elsif markdown_source?
      markdown.render(@json.dig('source', 'content') % { domain: Rails.configuration.x.local_domain })
    else
      ''
    end
  end

  def markdown_source?
    @json['source'].is_a?(Hash) &&
      @json.dig('source', 'content').present? &&
      %w(text/markdown text/x.misskeymarkdown).include?(@json.dig('source', 'mediaType'))
  end

  def markdown
    @markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML, escape_html: true, no_images: true)
  end

  def content_language_map?
    @json['contentMap'].is_a?(Hash) && !@json['contentMap'].empty?
  end

  def add_compatible_content(html)
    attachment_count = as_array(@json['attachment']).size
    return html unless !html.include?('original-media-link') && attachment_count > Setting.attachments_max.to_i

    url = sanitized_remote_url(@status_parser.url) || @uri
    Formatter.instance.add_original_link(html, url, I18n.t('statuses.attached.description', attached: attachment_count))
  end

  def strip_compatible_quote_link?
    return false if @status.quote_id.blank?

    candidate = quote_candidate_url
    return false if candidate.blank? || !same_existing_quote?(candidate)

    quote_link_hrefs.present? || (@json['quoteUri'].blank? && @json['_misskey_quote'].present?)
  end

  def quote_candidate_url
    quote_link_hrefs.first || @json['quoteUri'].presence || @json['_misskey_quote'].presence
  end

  def quote_link_hrefs
    @quote_link_hrefs ||= as_array(@json['tag']).filter_map do |tag|
      next unless tag.is_a?(Hash)
      next unless equals_or_includes?(tag['type'], 'Link')
      next unless tag['mediaType'] == 'application/ld+json; profile="https://www.w3.org/ns/activitystreams"'
      next unless as_array(tag['rel']).include?('https://misskey-hub.net/ns#_misskey_quote')
      next if tag['href'].blank?

      tag['href']
    end
  end

  def same_existing_quote?(url)
    quote = @status.quote
    return false if quote.nil? || url.blank?

    normalized = url.to_s.split('#').first
    quote_identities(quote).any? { |candidate| candidate.to_s.split('#').first == normalized }
  end

  def quote_identities(quote)
    [
      quote.uri,
      quote.url,
      ActivityPub::TagManager.instance.uri_for(quote),
      ActivityPub::TagManager.instance.url_for(quote),
    ].compact
  end
end
