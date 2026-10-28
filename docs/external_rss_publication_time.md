# External RSS publication time

A new external projection uses the article's publication instant as `statuses.created_at`. `Mastodon::Snowflake::Callbacks` mints the status id from that column. `updated_at` stays the time the row was saved. `override_timestamps` is not set.

This does not rewrite ids or `created_at` values that already exist. There is no backfill.

## Which instant is used

RSS reads `pubDate`, then `dc:date` / RSS 1.0 `date` when `pubDate` is missing or unparsable. Atom reads `published`, then `updated` when `published` is missing or unparsable. A non-empty but invalid `published` still falls through to a valid `updated`.

The parser accepts a full RFC 3339 date-time with a timezone, or an RFC 822 date-time with a timezone and a four-digit year. It does not treat a clock time or a bare date as "today". `lastBuildDate` and the HTTP `Last-Modified` header are not article publication times.

`ExternalResource.published_at` keeps the feed's instant, including a future one.

## What becomes `created_at`

On the first insert only:

| Feed instant | `statuses.created_at` |
| --- | --- |
| Strictly before now, on or after the Unix epoch, and inside the signed bigint snowflake range | That instant |
| Missing, unparsable, in the future, before the epoch, or too large for a signed bigint snowflake | `external_resources.created_at` |

Future means `published_at >= Time.current` at insert, with no grace period. `Snowflake::Callbacks` already refuses `created_at >= now` by minting an insertion-time id. A tolerance would widen that rule and could issue unbounded future ids. The first observation is stable: `fetched_at` is overwritten on every poll and is not the fallback.

A later poll, edit, or corrected date does not change the status id or `created_at`. The new instant remains on the resource. Display order stays aligned with id order because the status clock is not moved. Two articles in the same second get different ids; the random snowflake tail is not the feed's document order. The issued id is the tiebreak. Clients compare ids with the existing string comparator and do not coerce them through `Number`.

## Clients that only poll `since_id`

Home and list pages merge ordinary ids with external ids in status-id order. `since_id`, `max_id`, and `min_id` stay exclusive.

`since_id` returns ids **newer** than the cursor. A late article whose publication id is older than something the client has already seen is not in that response, even if the server stored it afterwards. Polling `since_id` alone cannot enumerate those rows. Load them with `max_id` / `min_id` over the range the client has already loaded, or reload the page without `since_id`. This server does not add an arrival cursor or another sync API.

The WebUI does not rely on `since_id` for that hole. A streamed external id that sits inside a loaded contiguous run is inserted there. Newer external ids still use the ordinary top-of-timeline and pending path. Reconnect, returning to the tab, the streaming HTTP fallback, and a column-header or mix refresh also rerun the loaded-range reconcile. A null gap stays open.

While `hasMore` is still true, a stream event does not extend the loaded tail. One id left after deletions keeps the original `max_id`, so the next older page can still load the posts in between. After an empty older page sets `hasMore` to false, an older external id is appended to that tail. The same refresh paths request one older page from that confirmed tail, so a missed stream event is recovered without reloading the whole column.
