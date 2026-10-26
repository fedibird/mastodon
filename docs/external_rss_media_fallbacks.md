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
`MediaDigest::FIELDS`, so adding or reordering only the alternates does not
change `media_revision`. The article body is still imported when the HTML
fragment cannot be read.

## Fetch

The job still carries the representative digest. `ImageAttempts` walks the
representative and then the fallbacks, at most four HTTP calls
(`MAX_IMAGE_FETCH_ATTEMPTS`). Each call uses the existing image rules and the
existing per-host budget.

| Failure | Next URL |
| --- | --- |
| 404 and other HTTP errors, bad MIME, undecodable bytes, oversized image | yes |
| timeout (`fetch_failed`), too many redirects | yes |
| SSRF or authenticated URL (`private_address`, `authenticated_source_rejected`, `unsupported_url`) | yes, and only a URL that already passed `MediaURL.normalize` |
| host budget (`rate_limited`) | no |

A URL that fails the normalizer is not requested. The code on the last
attempted URL is the one recorded when every URL fails. A timeout is still
`fetch_failed` and is still retried by the worker. A 404 is `http_404`.
Those codes are not collapsed.

When a later URL succeeds, the bytes are stored under that URL's digest. The
representative row is marked `alternate_selected` and has no file, so the
next refresh does not GET it again while the alternate is ready. The
projection attaches that one asset. The gallery sequence matches either
digest, so the picture is not also shown as a second attachment.

## Not in this increment

Conditional revalidation of an unchanged URL is P3-A. Browser playback is
P3-D and is not claimed here.
