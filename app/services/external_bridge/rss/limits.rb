# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Limits
      MAX_RESPONSE_BYTES = 1.megabyte
      MAX_TEXT_BYTES = 1.megabyte
      MAX_ITEMS = 40
      MAX_KEY_BYTES = 2_000
      HOST_BUDGET = 30
      HOST_WINDOW = 1.hour.to_i
      FRESH_FOR = 10.minutes
      TITLE_CHARS = 500
    end
  end
end
