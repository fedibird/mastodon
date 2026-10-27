# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Caps for the public discovery GETs. Ordinary permalinks are a sample,
      # not a crawl of the feed history.
      module Limits
        MAX_GETS_PER_RUN = 2
        ORDINARY_SAMPLE_CAP = 2
        CONFIRMED_HOST_SAMPLE_CAP = 8
        NEGATIVE_COOLDOWN = 30.days
        LEASE = 30.minutes
        RETRY_ERROR = 1.day
        RETRY_UNAVAILABLE = 7.days
        RETRY_VERIFIED = 7.days
      end
    end
  end
end
