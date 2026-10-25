# frozen_string_literal: true

module ExternalBridge
  # The owner-only display view of one projection Status. It names the
  # external source the content came from. It is not an account, it is not an
  # attributedTo, and it never falls back to the owner's own profile: the
  # Status keeps its real local Account and only the WebUI header changes.
  #
  # Every value is already cleaned for display here, and the client still
  # renders each one as text. `icon_url` is the stored copy of the feed's own
  # icon, shared by every subscriber of the source and served by Fedibird
  # (ExternalBridge::RSS::Icon::Delivery). It is nil until a validated image is
  # stored, and the client then draws its own protocol icon. The original
  # image URL, and ExternalActor.avatar_remote_url (an arbitrary third-party
  # URL this server never fetched or verified), are never passed through.
  # `thumbnail_url` is a reserved, nullable field and is always nil.
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
        icon_url: ExternalBridge::RSS::Icon::Delivery.url(source),
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
  end
end
