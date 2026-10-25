# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Limits
      MAX_RESPONSE_BYTES = 1.megabyte
      MAX_TEXT_BYTES = 1.megabyte
      MAX_ITEMS = 40
      # A refresh may replay at most one page of historical import failures.
      # After this many attempts an item is left alone until the owner resumes.
      ITEM_ATTEMPT_CEILING = 5
      MAX_KEY_BYTES = 2_000
      # btree index entries must stay under a page. Literal keys at or under
      # this size are stored as-is. Longer feed+item keys use a SHA256 form.
      MAX_RESOURCE_KEY_BYTES = 1_024
      HOST_BUDGET = 30
      HOST_WINDOW = 1.hour.to_i
      FRESH_FOR = 10.minutes
      TITLE_CHARS = 500
      # Feed icon fetch (issue #569). These bound one icon download, never the
      # feed fetch above.
      ICON_MAX_BYTES = 512.kilobytes
      ICON_MAX_PAGE_BYTES = 512.kilobytes
      ICON_MAX_DIMENSION = 4096
      ICON_MAX_PIXELS = 4_000_000
      ICON_MIN_DIMENSION = 16
      # width:height above this is a banner, not an icon, and is skipped.
      ICON_MAX_ASPECT = 2.0
      ICON_CANDIDATES = 6
      ICON_HINTS = 3
      ICON_HOST_BUDGET = 20
      ICON_TIMEOUTS = { connect_timeout: 5, read_timeout: 5, write_timeout: 5, read_deadline: 10 }.freeze
    end
  end
end
