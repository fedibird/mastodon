# frozen_string_literal: true

# Presentation helper for Mastodon's existing browser-local time display.
# Empty `time.formatted` tags are filled by `packs/public.js` using
# Intl.DateTimeFormat in the viewer's timezone and locale.
#
# The datetime attribute stays a canonical ISO8601 instant. This does not
# change storage, service JSON, or Rails Time.zone.
module BrowserLocalTimeHelper
  def formatted_browser_local_time(value)
    timestamp = coerce_browser_local_time(value)
    return if timestamp.nil?

    content_tag(:time, '', class: 'formatted', datetime: timestamp.iso8601)
  end

  private

  def coerce_browser_local_time(value)
    case value
    when Time, ActiveSupport::TimeWithZone
      value
    when String
      return if value.blank?

      Time.iso8601(value)
    end
  rescue ArgumentError
    nil
  end
end
