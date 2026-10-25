# External RSS feed icons

Issue #569. Builds on `fedibird_external.presentation` (#565, PR #566), which already reserved `icon_url` and drew a protocol glyph when it was null.

A shared, validated copy of each feed's icon is stored once per external source and shown in the subscription list and on external Status headers. No new flag was added: the job runs only while `Setting.external_bridge_rss` is on, and a tester sees an icon exactly where they could already see the feed.

## What was found first

| Area | Finding | Consequence |
| --- | --- | --- |
| Shared record | `external_sources` is one row per distinct public feed (`protocol`, `canonical_key`). Every subscriber's `external_subscriptions` row and every owner-private projection reaches it. | The icon lives on `external_sources`. Nothing is per user or per article. |
| Presentation | `ExternalBridge::Presentation.build` reads `source` from a preloaded `external_source` and wrote `icon_url: nil`. The WebUI only accepts same-origin icon URLs (`safeIconUrl`) and falls back to the RSS glyph on load error. | `icon_url` is filled from the source, so every past projection gets the icon once it is stored. The URL is a Fedibird route, so the client guard needs no change. |
| Stored media | Mastodon uses Paperclip (`has_attached_file`, `Attachmentable`, `remotable_attachment`; `NodeIcon` and `PreviewCardProvider#icon` are the closest cases). | `ExternalSource` uses `has_attached_file :icon` with the same storage, S3 and filesystem settings as every other attachment. No base64 in the database. |
| HTTP fetch | `ExternalBridge::RSS::HttpClient` goes through `Request` (public-only DNS check on every answer, redirect hook, byte limit, no credentials), plus `CanonicalURL`. | The icon job uses the same client. It gained a small `FetchProfile` (accept header, byte limit, content-type filter, timeouts, per-host budget namespace). The feed profile is unchanged. |
| URL rules | `CanonicalURL` fails closed on every query except `format=rss|atom|xml|feed`. Real icon URLs carry `?v=3`. | `CanonicalURL.normalize!(url, asset: true)` additionally allows up to three cache-busting pairs (`v ver version rev r t ts w h width height size s format cb`) with a value of at most 32 token-free characters. Every other name (`token`, `sig`, `key`, `expires`, ...) and userinfo are still rejected. |
| Job infrastructure | `RefreshSourceWorker` (queue `pull`, unique per args), `Scheduler::ExternalBridgeRSSRefreshScheduler`, advisory lock 810531. | `IconRefreshWorker`, `Scheduler::ExternalBridgeRSSIconScheduler`, advisory lock class 810532. |
| Specs | `Sidekiq::Testing.inline!` is on, so a queued job would run during every subscribe. | `spec/support/external_bridge_helpers.rb` stubs `IconRefreshWorker.perform_async`. The icon specs opt back in with `and_call_original`. |

PR #566 is already merged into `fedibird`. Nothing here depends on an unmerged change.

## Discovery order and the logo decision

Candidates are tried in this order. The first one that passes validation wins; at most six images are requested per attempt.

1. Atom `feed/icon`
2. RSS 2.0 `channel/image/url`
3. Atom `feed/logo`
4. The site page's `<link rel="icon">` / `shortcut icon` / `apple-touch-icon`, larger declared `sizes` first. `mask-icon`, `type=image/svg+xml` and `.svg` are skipped without a request.
5. `/favicon.ico` on the site origin

Relative URLs resolve against the document they appeared in: the feed URL for feed-declared images, the page's final URL for `<link>` tags. The page `<base>` element is ignored.

**Logo versus favicon.** The icon is drawn as a square (a 36 to 48 px avatar, and a 32 px list icon). Atom's `logo` is specified as a 2:1 banner and an RSS `image` is frequently an 88x31 button, so a feed-declared image is accepted only when its aspect ratio is at most 2:1 and each side is at least 16 px. A banner that fails this is skipped and the next candidate is tried, so a banner never wins over a usable favicon. A square logo beats a favicon because the feed owner chose it for the feed, whereas the favicon belongs to the whole site. `atom:icon` ranks above RSS `image` and Atom `logo` because it is the one element defined as a small square site icon. iTunes cover art (`itunes:image`) is a podcast cover, not a site icon, and is never read. An article's OG image is never read either.

**No substitution.** The site-derived candidates (4 and 5) use the feed's own site. A feed's `<link>` can name any host, so the site URL is used only when it shares a registrable domain (public suffix list) with the feed URL; otherwise the origin of the feed URL is used. One feed therefore cannot borrow another site's favicon by naming that site. Feed-declared images (1 to 3) may be on a CDN host, because the feed itself declared them.

## Validation (all must pass, otherwise nothing is stored)

- The URL is `http`/`https`, has no userinfo, no private literal host and no credential-like query. Redirects (at most 3) go through the same check before each hop, and `Request` checks every DNS answer at connect time, which covers rebinding.
- Status 2xx, `Content-Type` in `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/x-icon`, `image/vnd.microsoft.icon`, `image/ico`. SVG is rejected by type and by sniffing. A response without a type, or `application/octet-stream`, is rejected.
- At most 512 KiB, read through the byte limit. A bigger body is rejected, not truncated.
- The bytes must be recognized by FastImage as png/jpeg/gif/webp/ico, and the sniffed format must match the `Content-Type`. HTML, corrupt files and an empty body are rejected.
- At most 4096 px per side and 4,000,000 pixels, each side at least 16 px, aspect at most 2:1.
- 5 s connect, read and write timeouts and a 10 s read deadline. At most 20 icon requests per host per hour (separate from the feed budget of 30).
- ImageMagick runs with `-limit time 10 -limit area 32MP`. A GIF keeps only its first frame.

The site page is read only for its head: at most 512 KiB, `text/html` or `application/xhtml+xml`, cut rather than rejected.

## Storage and delivery

- Raster images are stored as a 128 px square WebP (`style :original`), with the original file name obfuscated by `Attachmentable`. The file never leaves Mastodon's storage layer.
- An ICO is stored as fetched through `Paperclip::PassThrough` (`lib/paperclip/pass_through.rb`). It was already checked for type, size and dimensions, and it never reaches ImageMagick's ICO coder. In particular the ICO coder is disabled by the default ImageMagick policy on some distributions, and a favicon must not depend on loosening it.
- Columns on `external_sources`: the Paperclip set (`icon_file_name`, `icon_content_type`, `icon_file_size`, `icon_updated_at`), `icon_fingerprint` (SHA-256 of the downloaded bytes), `icon_remote_url` and `icon_origin` (where it came from and which rule picked it), `icon_etag` and `icon_last_modified` (validators), `icon_hints` (the feed-declared candidates, `jsonb`), `icon_checked_at`, `icon_next_check_at`, `icon_failure_count`, `icon_error_code`. The original URL is never returned by any API.
- The address given to clients is `/external_source_icons/:source_id/:fingerprint` (`ExternalSourceIconsController`). It answers 302 to the media storage URL with `Cache-Control: public, max-age=86400`. It needs no sign-in because the icon is a public, shared image, but it resolves only for the fingerprint of the stored file, so a replaced icon has a new address and the old one is a 404. In limited-federation mode it requires sign-in like `media_proxy`.
- Because the route is same-origin, the existing client guard (`safeIconUrl`) accepts it whatever `S3_ALIAS_HOST` is.

## When it runs

- **New source, first success.** `Ingest.apply_public!` writes `icon_hints` with the other public fields. `Subscribe` and `RefreshSource` call `Icon::Schedule.enqueue_if_due` after a successful fetch or 304. A failed push is logged and ignored.
- **Not per article, user or poll.** `icon_next_check_at` is the single gate: `IconRefreshWorker` is unique per source in Sidekiq, and `RefreshSource` returns `skipped_not_due` if the time has not come. Two subscribers, or a hundred polls, make one download.
- **Success.** The next check is in 7 days. It is a conditional GET to `icon_remote_url` with `If-None-Match` and `If-Modified-Since`. A 304 keeps the file. The same bytes without validators keep the file. Changed bytes replace the attachment (Paperclip removes the old files after the save).
- **Failure.** Backoff of 1 hour, 6 hours, 24 hours, 3 days, then 7 days. A stored icon is kept through transient failures. If the stored address now answers 404 or 410, or with something that is no longer a valid image, discovery starts over.
- **Changed declaration.** If the feed's declared hints change, the icon becomes due again, but at most once an hour, so a feed that rewrites the URL on every request cannot cause a download per poll.
- **Existing subscriptions (backfill).** `Scheduler::ExternalBridgeRSSIconScheduler` (every 15 minutes) queues at most 20 sources that are fetched, have an active subscription by a tester, and are due (never checked, or the weekly re-check or backoff has arrived). A source created before this change has `icon_hints = NULL`; the job reads the feed once to learn the declared images, so it starts with the same ordering a new source gets.
- **Concurrency.** One PostgreSQL advisory lock (class 810532, per source) skips a second concurrent run. The write takes the row `FOR UPDATE`, so a source that disappeared meanwhile is skipped and nothing is stored.
- **Failure isolation.** The icon job never raises into feed refresh, subscription update or projection creation, and `Schedule.enqueue_if_due` swallows queue errors. It writes only `external_sources.icon_*`.

Logs are one `[ExternalBridge::RSS] event=icon ...` line per run through `RefreshLog` (outcome, error code, candidate count, elapsed). URLs, headers and image bytes never reach the log.

## What did not change

`Status.account`, account ids, `attributedTo`, owner-only authorization, visibility, private projection storage and the streaming payload shape are untouched. `icon_url` is one more value in a hash the owner already received; clients that ignore it are unaffected, and it is `null` until an icon is stored and on any failure. A status streamed before the icon was stored keeps `icon_url: null` in that payload until the client reloads it. The ActivityPub, public delivery, Bluesky and article-media paths are not touched. `thumbnail_url` stays `null`.

## UI

The subscription list (`Settings::ExternalServices::RSS`) shows a 32 px icon beside the feed title. The default RSS glyph is always rendered first and the stored image is laid over it, so a feed with no stored icon, a failed fetch, or an image that fails to load shows the glyph, with no script. The title column wraps below the badge on small screens (`flex: 1 1 120px`). `ExternalSourceIcon` in the WebUI already falls back to the glyph on `onError`.

## Flags, migration and existing data

- Migration `20261031120000_add_icon_to_external_sources` adds 14 columns, all nullable or with a constant default (`icon_failure_count integer NOT NULL DEFAULT 0`). On PostgreSQL 11+ this is a catalog change; no row is rewritten and no index is added. It is reversible. Do not run it in production from this change.
- No feature flag was added or changed. Nothing happens while `external_bridge_rss` is off or the tester list is empty.
- Existing sources start with `icon_next_check_at IS NULL`, which means "due"; the scheduler works through them 20 at a time.

## Tests

`spec/services/external_bridge/rss_icon_spec.rb`, `rss_icon_schedule_spec.rb`, `spec/requests/external_source_icons_spec.rb`, `spec/requests/api/v1/external_bridge/icon_presentation_spec.rb`, `spec/controllers/settings/external_services/rss_icons_spec.rb`, and one case in `app/javascript/mastodon/external_presentation/__tests__/identity-test.js`.
