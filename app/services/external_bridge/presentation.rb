# frozen_string_literal: true

module ExternalBridge
  # The owner-only display view of one projection Status. It names the
  # external source the content came from. It is not an account, it is not an
  # attributedTo, and it never falls back to the owner's own profile: the
  # Status keeps its real local Account and only the WebUI header changes.
  #
  # Every value is already cleaned for display here, and the client still
  # renders each one as text. `icon_url` is either nil or an https URL that
  # this instance serves itself (its own web origin, CDN_HOST, or the
  # S3 alias host). A raw third-party image URL is never passed through; with
  # no managed copy the client draws its own protocol icon.
  module Presentation
    KIND = 'external_source'
    NAME_LIMIT = 120
    BYLINE_LIMIT = 120
    SUBTITLE_LIMIT = 40
    URL_LIMIT = 2048

    # Preload tree for a page of statuses: one query per level for the whole
    # page, none when the page holds no projection.
    PRELOAD = [:external_source, { external_resource: [:external_source, :external_actor] }].freeze

    PROTOCOL_LABELS = {
      'rss' => 'RSS',
      'atom' => 'Atom',
    }.freeze

    CONTROL_CHARACTERS = /[\p{Cc}\u2028\u2029]/.freeze
    # Direction overrides could reorder the name around the label beside it.
    DIRECTION_CONTROLS = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/.freeze

    module_function

    def build(projection)
      resource = projection&.external_resource
      source   = resource&.external_source || projection&.external_source
      actor    = resource&.external_actor
      protocol = (source&.protocol || resource&.protocol || actor&.protocol).to_s.presence
      label    = PROTOCOL_LABELS[protocol]

      {
        kind: KIND,
        name: clean_text(source&.title, NAME_LIMIT) || clean_text(actor&.display_name, NAME_LIMIT) || label,
        subtitle: label,
        source_url: source_url(source, actor),
        icon_url: icon_url(actor),
        thumbnail_url: nil,
        byline_name: clean_text(resource&.byline, BYLINE_LIMIT),
      }
    end

    def clean_text(value, limit)
      text = value.to_s.scrub('').gsub(DIRECTION_CONTROLS, '').gsub(CONTROL_CHARACTERS, ' ').squish
      return nil if text.empty?

      text.length > limit ? "#{text[0, limit - 1]}…" : text
    end

    # A site or profile page, never the article. A URL the RSS layer would not
    # accept as a public address (credentials, private literals, odd queries)
    # is dropped, and the client then renders the name without a link.
    def source_url(source, actor)
      [source&.site_url, actor&.profile_url].each do |candidate|
        url = normalize_url(candidate)
        return url if url
      end

      nil
    end

    def normalize_url(value)
      return nil if value.blank? || value.to_s.length > URL_LIMIT

      url = ExternalBridge::RSS::CanonicalURL.normalize!(value)
      url.length > URL_LIMIT ? nil : url
    rescue ExternalBridge::Error
      nil
    end

    def icon_url(actor)
      value = actor&.avatar_remote_url
      return nil if value.blank? || value.length > URL_LIMIT

      uri = Addressable::URI.parse(value)
      return nil unless uri&.scheme&.downcase == 'https' && uri.host.present?
      return nil if uri.user.present? || uri.password.present?
      return nil unless managed_hosts.include?(uri.host.downcase)

      uri.to_s
    rescue Addressable::URI::InvalidURIError
      nil
    end

    def managed_hosts
      hosts = [Rails.configuration.x.web_domain, ENV['S3_ALIAS_HOST'], ENV['S3_CLOUDFRONT_HOST'], cdn_host]
      hosts.filter_map { |host| host.to_s.sub(%r{\Ahttps?://}i, '').split('/').first.presence&.downcase }.uniq
    end

    def cdn_host
      Rails.configuration.action_controller.asset_host.then { |host| host.is_a?(String) ? host : nil }
    end
  end
end
