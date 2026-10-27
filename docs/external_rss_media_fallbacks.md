# Image candidate fallback

Issue #588, P3-C. One `<picture>` or `<img>` stays one logical attachment.
The representative URL is unchanged from the previous ranking, and the other
acceptable URLs are kept on that candidate as `fallbacks`.

## How a URL is chosen

`srcset` `w` is a declared width. `x` is a density and does not invent a
width. The representative is the greatest width. Equal widths prefer WebP
(`type` containing `webp`, or a `.webp` path) and then the higher density.
An `<img>` that has no positive width keeps its `src`; the `x` entries are
fallbacks. That is the previous `<img>` rule, so `media_revision` does not
move just because fallbacks are now stored.

`<source media>` is not evaluated. The server does not know the reader's
viewport, so a `min-width` source is eligible when its width wins. `type` is
used for the WebP tie-break and is checked again when the bytes arrive.

`javascript:`, `data:`, credentials, private address literals, and SVG are
dropped before they are stored. They are never a fallback. A later fetch
still runs the existing SSRF and redirect checks on each URL it actually
requests.

`fallbacks` holds at most four URLs (`MAX_IMAGE_FALLBACKS`). It is not one of
`MediaDigest::FIELDS`, so adding, removing, or reordering only the alternates
does not change `media_revision` or the article text revision.
`ImageAttempts.fingerprint` is a separate hash of the ordered safe URL list.
The article body is still imported when the HTML fragment cannot be read.

## When only the fallback list changes

A refresh still compares the projection's attachments with the URLs listed
now (`Media::Sync.links_stale?`). That comparison does not bump
`last_seen_media_revision`.

| What changed | What a refresh does |
| --- | --- |
| The attached digest is no longer a candidate, and another ready candidate is listed | Attach that file, drop the old link, and plan the old file for GC |
| The attached digest is no longer a candidate, and nothing ready replaced it | Drop the old link and plan it for GC |
| A new fallback is listed after every previous URL failed three times for this revision | The new fingerprint is not exhausted, so the chain runs again |
| The attached digest is still listed, but its shared file is temporarily not ready | Leave the attachment. The fetch chain below replaces the bytes |
| The attachment is `incoming:{id}` or `superseded:{id}`, or the ready file still has an `incoming:{id}` checkpoint | Leave it. That is a generation swap in progress, not a fallback change |

The resource link used for revalidation is removed when that digest leaves
the candidate list, so the old fallback is not conditional-GET afterwards.

## Fetch

The job still carries the representative digest. `ImageAttempts` walks the
representative and then the fallbacks. Four stored fallbacks plus the
representative are five HTTP calls (`MAX_IMAGE_FETCH_ATTEMPTS`). Each call
uses the existing image rules and the existing per-host budget. A 304 for
the URL that was actually stored, including a fallback, with a missing
local file is `local_missing`. The follow-up job is keyed by the
representative digest and GETs without validators, so a server that keeps
answering 304 still restores that fallback on the same job.

| Failure | Next URL |
| --- | --- |
| 404 and other HTTP errors, bad MIME, undecodable bytes, oversized image | yes |
| timeout (`fetch_failed`), too many redirects | yes |
| SSRF or authenticated URL (`private_address`, `authenticated_source_rejected`, `unsupported_url`) | yes, and only a URL that already passed `MediaURL.normalize` |
| host budget (`rate_limited`) | no |

A URL that fails the normalizer is not requested. When every URL fails, the
representative row keeps the last error (`http_404`, `fetch_failed`, and the
rest stay distinct) and `attempt_log` keeps each tried digest with its own
code. A fallback's 404 or broken image is also written on that URL's row
when the row is not already a ready file or an exhausted representative.
The log stores digests and codes only, never URLs. A timeout is still
`fetch_failed`. `rate_limited` still stops the chain, is not written as a
content failure, and does not move `attempt_count`.

When a later URL succeeds, the bytes are stored under that URL's digest. The
representative row is marked `alternate_selected`, `attempt_count` is 0, and
it has no file. The next refresh does not GET it again while a current
fallback is ready. The projection attaches that one asset. The gallery
sequence matches either digest, so the picture is not also shown as a second
attachment.

## Retry

`ImageAttempts.chain_open?` is the gate for the representative row.

| Row | Chain |
| --- | --- |
| Missing, or failed under the attempt cap | Run |
| `alternate_selected` and a current fallback is ready | Do not GET |
| `alternate_selected` and no current fallback is ready | Run again. A 404 on the representative is requested again. The fallback that used to be ready is requested again. A new fallback in the list is requested too |
| Exhausted for this media revision and this fingerprint | Stop |
| Same revision, fingerprint changed | Run. The next terminal failure starts the budget at 1 |
| `processing_blocked?` or `rate_limited` | Stop this pass. `rate_limited` does not count |

Three terminal failures of one fingerprint stop retries until the fallback
list changes. Choosing an alternate resets that budget. A later chain that
fails for the same fingerprint counts from one again. The shared file and
the status attachment stay on the last ready fallback until that chain
stores a replacement or the fallback leaves the candidate list.

## Not in this increment

Conditional revalidation of an unchanged URL is P3-A. A changed body of the
URL that was actually stored, including a fallback, uses that generation
swap. The resource link moves when the article still lists the digest.
Browser playback is P3-D and is not claimed here.
