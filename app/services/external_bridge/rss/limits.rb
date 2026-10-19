# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Limits
      MAX_RESPONSE_BYTES = 1.megabyte
      MAX_TEXT_BYTES = 1.megabyte
      MAX_ITEMS = 40
      MAX_KEY_BYTES = 2_000
      # btree index entries must stay under a page. Literal keys at or under
      # this size are stored as-is. Longer feed+item keys use a SHA256 form.
      MAX_RESOURCE_KEY_BYTES = 1_024
      HOST_BUDGET = 30
      HOST_WINDOW = 1.hour.to_i
      FRESH_FOR = 10.minutes
      TITLE_CHARS = 500
    end
  end
end
