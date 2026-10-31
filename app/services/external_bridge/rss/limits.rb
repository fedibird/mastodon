# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Limits
      # Inflated body of one feed response, in bytes. This is the document
      # the parser would see. Phase 1 keeps the previous 4 MiB ceiling.
      # Podcast feeds can contain years of episodes; the parsed item count is
      # independently bounded by MAX_ITEMS below. 8 MiB is an unadopted
      # candidate and is not this constant.
      MAX_RESPONSE_BYTES = 4.megabytes
      # Encoded body of one HTTP response, in bytes, after transfer framing
      # (including chunked framing) is removed and before Content-Encoding
      # is inflated. TLS records and header bytes are not included.
      # Content-Length describes this size when it is present and honest; a
      # missing, invalid, or short value does not replace the count of bytes
      # actually read. The default matches MAX_RESPONSE_BYTES so a public
      # feed still cannot accept more than 4 MiB on the wire. The two caps
      # are independent: a test profile may raise one without raising the
      # other. This phase does not.
      MAX_RECEIVED_BYTES = 4.megabytes
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
      # One icon run holds a database transaction (and its advisory lock), so
      # it must not keep trying candidates indefinitely.
      ICON_RUN_DEADLINE = 40
      ICON_TIMEOUTS = { connect_timeout: 5, read_timeout: 5, write_timeout: 5, read_deadline: 10 }.freeze
      # Article media (issue #585). Images are downloaded. Videos are not,
      # unless a later server policy says otherwise. The candidate cap is the
      # hard attachment ceiling; the live post limit can be lower.
      MAX_MEDIA_CANDIDATES = 12
      # Alternate renditions stored for one media:group. Selection may look
      # at every eligible rendition the scan budget reached, then keeps this
      # many, always including the representative. These do not each spend a
      # MAX_MEDIA_CANDIDATES slot. Image fallbacks are a different cap.
      MAX_GROUP_VARIANTS = 8
      # Element nodes visited inside one item's media:group trees: contents,
      # players, thumbnails, titles, rejected nodes, and nested groups.
      MAX_GROUP_SCAN = 64
      # Nested media:group elements entered under one item. The outermost
      # group is depth 1. A deeper group is not read.
      MAX_GROUP_DEPTH = 4
      MAX_MEDIA_DESCRIPTION = 500
      # One player per item. The HTML fragment is discarded after src is read.
      MAX_EMBED_HTML_BYTES = 8.kilobytes
      MAX_EMBED_SCAN = 4
      MAX_KEYWORDS = 16
      MAX_KEYWORD_CHARS = 40
      MAX_MEDIA_DURATION = 48.hours.to_i
      # Extra URLs kept for one logical image. They are not part of the media
      # revision. A fetch tries the representative and every stored fallback,
      # so the attempt cap is one larger than the number of fallbacks.
      MAX_IMAGE_FALLBACKS = 4
      MAX_IMAGE_FETCH_ATTEMPTS = MAX_IMAGE_FALLBACKS + 1
      MEDIA_IMAGE_MAX_BYTES = 8.megabytes
      MEDIA_IMAGE_MAX_DIMENSION = 8_192
      MEDIA_IMAGE_MAX_PIXELS = 40_000_000
      MEDIA_HOST_BUDGET = 20
      MEDIA_INFLIGHT = 4
      # How long one fetch waits for a free slot or for another worker that is
      # already downloading the same URL. Past this, the job raises and Sidekiq
      # retries. It is not recorded as a content failure.
      MEDIA_INFLIGHT_WAIT = 8
      # How long a second worker waits to take a URL lock before it retries
      # through Sidekiq. This is not the lock's lifetime.
      MEDIA_URL_LOCK_WAIT = 15
      MEDIA_IMAGE_TIMEOUTS = { connect_timeout: 5, read_timeout: 10, write_timeout: 5, read_deadline: 20 }.freeze
      MEDIA_VIDEO_TIMEOUTS = { connect_timeout: 5, read_timeout: 20, write_timeout: 5, read_deadline: 60 }.freeze
      # Redis lease for the worker that is downloading. It is longer than one
      # image or video read, and URLLock renews it until that download returns.
      # A fixed 15s TTL expired while a slow GET was still running.
      MEDIA_URL_LOCK_LEASE = [
        MEDIA_IMAGE_TIMEOUTS[:connect_timeout] + MEDIA_IMAGE_TIMEOUTS[:write_timeout] + MEDIA_IMAGE_TIMEOUTS[:read_deadline],
        MEDIA_VIDEO_TIMEOUTS[:connect_timeout] + MEDIA_VIDEO_TIMEOUTS[:write_timeout] + MEDIA_VIDEO_TIMEOUTS[:read_deadline],
      ].max + 30
      # Revalidation is not part of a feed fetch. One refresh may enqueue this
      # many conditional GETs, and the scheduler pass is capped separately.
      MEDIA_REVALIDATE_AFTER = 24.hours
      MEDIA_REVALIDATE_PER_REFRESH = 2
      MEDIA_REVALIDATE_BATCH = 10
      # One generation swap repoints at most this many projections, each in
      # its own transaction. The next pass continues the same incoming row.
      MEDIA_REPOINT_BATCH = 8
      # A prepared subscriber file is owned by a stage row for this long.
      # Reclaim runs only after the lease has lapsed, so a second worker
      # still inside its copy is left alone.
      MEDIA_REPOINT_PREPARE_LEASE = 2.minutes
    end
  end
end
