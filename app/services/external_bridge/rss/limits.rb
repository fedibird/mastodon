# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Limits
      # Inflated body of one feed response, in bytes. This is the document
      # the parser would see. 8 MiB covers the measured public-feed shape
      # (about 6.3 MiB and 1,017 items) with headroom. One parse of that
      # fixture is about 110–150 ms and peaks near 80–100 MB RSS, including
      # the interpreter. A response may contain more than MAX_ITEMS keyed
      # items. Those stay in a snapshot and are imported
      # SNAPSHOT_BATCH_ITEMS at a time. MAX_ITEMS remains the history page.
      MAX_RESPONSE_BYTES = 8.megabytes
      # Encoded body of one HTTP response, in bytes, after transfer framing
      # (including chunked framing) is removed and before Content-Encoding
      # is inflated. TLS records and header bytes are not included.
      # Content-Length describes this size when it is present and honest; a
      # missing, invalid, or short value does not replace the count of bytes
      # actually read. This cap is independent of MAX_RESPONSE_BYTES. It is
      # the same number because an identity-encoded copy of the same feed
      # uses that many received bytes. Gzip of the synthetic fixture is much
      # smaller, which is not a reason to reject the uncompressed form.
      MAX_RECEIVED_BYTES = 8.megabytes
      # Bytes of the string given to Parser.parse!, counted before a document
      # exists. This is not BodyReader's cap. A caller that already holds a
      # body still cannot parse past it. The number matches MAX_RESPONSE_BYTES
      # so a direct parse cannot accept a feed the client rejects. The
      # constants are separate; raising one does not raise the other.
      MAX_PARSE_BYTES = 8.megabytes
      # Element nesting. The root element is depth 1. A synthetic 1,017-item
      # feed is depth 4. 64 leaves room for an XHTML entry body. libxml's own
      # ceiling still applies because the parser does not set HUGE.
      MAX_XML_DEPTH = 64
      # Element start tags in the whole document, including items that will
      # not be stored. A generated feed of this many elements (40 real items,
      # the rest empty) is about 400 KiB. Parser.parse! returned 40 items in
      # about 200 ms and peaked near 79 MB RSS, from about 54 MB before the
      # parse. The 6,107-element synthetic feed is far under this.
      MAX_XML_ELEMENTS = 100_000
      # xmlTextReaderAttributeCount on one element, including xmlns.
      # Media RSS attributes and a handful of namespaces sit under this.
      MAX_XML_ATTRIBUTES = 64
      # Sum of those per-element counts. An 8 MiB document with about 1.1
      # million attributes peaked near 339 MB on one thread, so the byte cap
      # alone does not bound the DOM. 100_000 elements plus about 100_000
      # attribute nodes peaked near 103 MB, and five threads in one process
      # peaked near 305 MB. That is the accepted structural worst case.
      MAX_XML_ATTRIBUTES_TOTAL = 100_000
      # One text, CDATA, or comment node, in bytes. It matches the document
      # cap so a description the byte budget already accepted is not rejected
      # again. Entity expansion that materializes a larger node fails here,
      # before the DOM exists. MAX_TEXT_BYTES is the later storage cap.
      MAX_XML_TEXT_BYTES = MAX_PARSE_BYTES
      # One attribute value, in bytes. Feed URLs fit. A multi-megabyte
      # attribute does not.
      MAX_XML_ATTRIBUTE_BYTES = 64.kilobytes
      MAX_TEXT_BYTES = 1.megabyte
      # Initial history, shared-cache materialize, failure replay, and the
      # first-subscription language sample. Not the parse cap and not the
      # number of new items a continued subscription may import.
      MAX_ITEMS = 40
      # One drain job after the synchronous history page. The same size as
      # MAX_ITEMS because that is the page Materialize already applies in
      # one pass. A larger page would hold the projection locks longer; a
      # smaller page would multiply feed reparses. It is not a reason to
      # stop at the first 40 keyed items.
      SNAPSHOT_BATCH_ITEMS = 40
      # Keyed items kept from one response. Document budgets still reject
      # hostile XML first. 4,096 is above the measured public feed (about
      # 1,017 items) and far below MAX_XML_ELEMENTS. Crossing it fails the
      # snapshot and does not advance validators, so the tail is not dropped
      # and the next poll can retry.
      SNAPSHOT_MAX_ITEMS = 4_096
      # Unfinished snapshots kept per source. A newer response is stored
      # behind them. Past this, the new body is refused and the stored
      # bodies stay. 3 is one in flight plus a fetch that arrived during
      # the drain and one more, which is the most a single source can owe
      # while each body is still at most MAX_PARSE_BYTES.
      SNAPSHOT_OPEN_LIMIT = 3
      # Successful tail batches for one snapshot. 4,096 / 40 is 102.4, plus
      # room for a short batch. The history page does not consume one.
      # Past this the snapshot fails instead of enqueueing itself again.
      SNAPSHOT_MAX_BATCHES = 160
      # How long a drain worker owns a snapshot. A second worker does not
      # enter until this lapses. The worker renews it on every item. Two
      # minutes covers one batch of projection writes without letting a
      # dead process block the source until the next scheduler pass.
      SNAPSHOT_LEASE = 2.minutes
      # A finished body becomes eligible for removal this long after
      # completed_at (or updated_at when that is nil). The RSS scheduler
      # pass, and a capture or drain, delete at most SNAPSHOT_PURGE_BATCH
      # eligible bodies. Eligibility is not the moment of deletion: an idle
      # source waits for the next pass, which is the existing 15 minute
      # scheduler tick, not a new feed poll.
      SNAPSHOT_BODY_RETENTION = 24.hours
      SNAPSHOT_PURGE_BATCH = 50
      # Sum of byte_size for finished bodies that still hold text. Open
      # bodies are outside this cap (SNAPSHOT_OPEN_LIMIT bounds those per
      # source). The purge drops the oldest finished bodies until the sum
      # fits or the batch is spent. 32 MiB is four responses at the feed
      # byte cap.
      SNAPSHOT_RETAINED_BODY_BYTES = 32.megabytes
      # Failures of the same cursor position before that position is
      # isolated. The snapshot stays open and the rest of the generation
      # still runs. The isolated position is not retried until
      # FeedSnapshot::Retry. This is not a Sidekiq retry budget.
      SNAPSHOT_ATTEMPT_CEILING = 5
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
