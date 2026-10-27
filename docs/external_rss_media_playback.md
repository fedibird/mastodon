# External video and audio playback

Issue #588, P3-D. The owner already chose to subscribe to the feed. There is
no second consent screen. Fedibird does not proxy the remote file in the
default `remote` policy, and a hybrid copy is only created inside the
existing size cap. This note is the device gate. It does not record a pass
for a browser that was not run.

## What the browser is asked to do

Remote video and audio are not `MediaAttachment` rows. `media-src` in
`config/initializers/content_security_policy.rb` is `'self' https: data:`
plus the asset host. An `http://` file on another host is blocked by CSP.
`https://` is allowed. The element is created only after the owner clicks.
`autoplay` is not set. `preload` is `none`. `referrerpolicy` is
`no-referrer`, which HTML media does not guarantee. The browser, not
Fedibird, follows redirects and sends `Range` when the user seeks.

If the element fires `error`, the `src` is removed. The UI links to the
media URL and, when the projection has one, the article `canonical_url`,
and shows Try again. Try again clears that failure and returns to the
button that has no `src`. The next click assigns `src` again and does not
autoplay. A payload that has `fedibird_external.media` but no `sequence`
still receives `canonical_url` as that article link. `javascript:` and
credential URLs are not used for either link.

Saved images and a saved video stay on the local gallery and the local
player, including picture-in-picture for the saved player. A remote file
uses the browser's native controls. A sensitive or content-warning status
keeps the remote block behind the same overlay as other media. A processing
failure while hybrid mode is copying a video leaves the remote player in
place. That path is covered by the hybrid specs, not by a device.

## Formats

| File | Fixture | What to expect |
| --- | --- | --- |
| MP4 (`video/mp4`) | `playback-story` / `playback.mp4` | Native `<video>` after click. |
| WebM (`video/webm`) | `playback-story` / `playback.webm` | Native `<video>` where the browser supports WebM. |
| HLS (`.m3u8`) | `playback-story` / `playback.m3u8` | Safari may play it as `src`. Chrome and Firefox do not, because this build does not include an HLS library. The error fallback should appear. |
| MP3 (`audio/mpeg`, `<audio><source>`) | `playback-story` / `playback.mp3` | Native `<audio>` after click. |
| HTTP 403 | `playback-forbidden` / `playback-forbidden.mp4` | Error fallback: Try again, Open media file, Open article. No second consent screen. |
| Unsupported MIME | `playback-unsupported-mime` / `playback-unsupported.mp4` | The feed marks it as video so a player is offered. The test server answers `200` with `Content-Type: application/octet-stream` and bytes that are not a media file. The error fallback should appear. |
| `Range` ignored | `playback-no-range` / `playback-no-range.mp4` | The test server answers `200` `video/mp4` and answers `Range` with the whole file (`200`, not `206`). Seek may stall or fire `error`. |

Fedibird does not send `HEAD` for these remote files. A publisher that
rejects `HEAD`, returns 403, or ignores `Range` is visible only in the
browser. Seeking then either works, stalls, or fires `error`. The XML
fixture does not create those HTTP responses. The server contract below
does. A row stays `not run` until someone records the response they saw.

## Not run in this environment

iOS Safari, iOS PWA (standalone), Chrome desktop, Chrome Android, and a
real publisher CDN were not executed here. No row below is a pass.

| Check | Fixture | iOS Safari | iOS PWA | Chrome desktop | Chrome Android |
| --- | --- | --- | --- | --- | --- |
| Click does not autoplay; `src` appears only then | `playback-story` | not run | not run | not run | not run |
| MP4 plays with native controls | `playback.mp4` | not run | not run | not run | not run |
| WebM plays or shows the fallback | `playback.webm` | not run | not run | not run | not run |
| HLS plays only where the browser supports it, otherwise the fallback | `playback.m3u8` | not run | not run | not run | not run |
| MP3 plays with native `<audio>` controls | `playback.mp3` | not run | not run | not run | not run |
| Seek / `Range` on a byte-serving MP4 | `playback.mp4` | not run | not run | not run | not run |
| A file that ignores `Range` stalls or shows the fallback | `playback-no-range.mp4` | not run | not run | not run | not run |
| Publisher 403 shows the fallback, not a second consent screen | `playback-forbidden.mp4` | not run | not run | not run | not run |
| A redirect of the media URL plays the final file or shows the fallback, with no second consent screen | not in the fixture; record it when a publisher redirects | not run | not run | not run | not run |
| Unsupported MIME shows the fallback | `playback-unsupported.mp4` | not run | not run | not run | not run |
| Try again removes `src` until the next click and does not autoplay | any error row | not run | not run | not run | not run |
| Sensitive overlay hides the remote block until reveal | `playback-story` | not run | not run | not run | not run |
| Image, remote video, and remote audio stay in article order | `playback-story` | not run | not run | not run | not run |
| Picture-in-picture on a saved local video | saved attachment, not this fixture | not run | not run | not run | not run |
| Hybrid copy failure still offers the remote player | hybrid specs, not this fixture | not run | not run | not run | not run |

## Device task

Merging the playback change does not finish P3-D and does not mean the
compatibility check was done. Issue #588 stays the tracker. This section is
the open task for the device gate. No cell above is a pass, and this file
must not be edited to say `pass` unless the result log below was filled
from a run on that device.

- **Status:** open. Nothing in this pull request closes it.
- **Owner:** unassigned. The person who has the device writes the result log. This document does not name a pass for them.
- **Devices:** iOS Safari, iOS PWA (home-screen standalone), Chrome desktop, Chrome Android. A device that was not used stays `not run`.

### Reproduction

1. Copy `spec/fixtures/external_bridge/playback_feed.xml`. Replace `cdn.example` and `example.com` with **https** origins the CSP allows (`media-src` is `'self' https:` plus the asset host). An `http://` file on another host is a CSP check, not a format result: record it in the CSP field and do not use it to fill a format row.
2. Serve the media URLs with the contract in the next table. The XML only names the URLs. If the server does not answer that way, leave the row `not run`.
3. Subscribe as a tester with `external_bridge_rss` enabled. Open each projected status.
4. For one device at a time, copy the result block and fill it from that run. `pass` and `fail` are written only for a step that person performed. Copying another browser's result is not a run.

Expected UI before any device result is recorded:

1. On `playback-story`, the image is a local attachment. MP4, WebM, HLS, and MP3 are buttons. The document does not contain those media URLs until a button is clicked. Nothing plays by itself.
2. A click assigns `src` once. Controls show without a second click. `autoplay` is absent.
3. On `playback-forbidden`, `playback-unsupported-mime`, and a browser that cannot play HLS, the player is removed. Try again, Open media file, and Open article (the item's `<link>`) are shown.
4. Try again returns to the button. The media URL leaves the document. The next click assigns `src` again and does not autoplay.
5. On `playback-no-range`, seeking is observed and written down. Stall and error are both real outcomes. Neither is assumed.
6. Collapsing a sensitive warning removes the player and the URLs again.

Jest covers the click, the missing `src`, the error links, Try again, and the article link when `sequence` is absent. It does not play media. The parser example `maps the playback gate fixture onto the device cases` only checks that the feed still exposes these URLs. It is not a device pass.

### Server contract

| Fixture guid | Media URL | Markup | What the test server returns | Spec row |
| --- | --- | --- | --- | --- |
| `playback-story` | `https://cdn.example/playback.png` | `<img>` | `200`, image bytes | Image order |
| `playback-story` | `https://cdn.example/playback.mp4` | `<video><source type="video/mp4">` | `200` `video/mp4`, `Accept-Ranges: bytes`, `Range` answered with `206` | MP4, seek |
| `playback-story` | `https://cdn.example/playback.webm` | `<video><source type="video/webm">` | `200` `video/webm` | WebM |
| `playback-story` | `https://cdn.example/playback.m3u8` | `<video><source type="application/vnd.apple.mpegurl">` | `200` HLS playlist | HLS |
| `playback-story` | `https://cdn.example/playback.mp3` | `<audio><source type="audio/mpeg">` | `200` `audio/mpeg` | MP3 |
| `playback-forbidden` | `https://cdn.example/playback-forbidden.mp4` | `<video><source type="video/mp4">` | `403` | Publisher 403 |
| `playback-unsupported-mime` | `https://cdn.example/playback-unsupported.mp4` | `<video><source type="video/mp4">` | `200` `Content-Type: application/octet-stream`, body is not a media file | Unsupported MIME |
| `playback-no-range` | `https://cdn.example/playback-no-range.mp4` | `<video><source type="video/mp4">` | `200` `video/mp4`, no `Accept-Ranges`, `Range` answered with `200` of the whole file | Range ignored |

Article links in the fixture are `https://example.com/playback-story`, `https://example.com/playback-forbidden`, `https://example.com/playback-unsupported-mime`, and `https://example.com/playback-no-range`. Replace the host with the https origin you serve, then expect Open article to use that replaced URL.

### Result log

No run is recorded. Copy the block once per device that is actually used. Leave a field empty when that step was not performed. Do not write `pass` in advance.

```
Device:
Tester:
Date:
Build URL:
Status URL opened:
Fixture guid:
Media URL requested:
Format / Content-Type observed:
HTTP status:
Range / seek (Range sent, Content-Range or Accept-Ranges, what seek did):
CSP (media-src console message, or none observed):
Error UI (player removed, Try again, Open media file, Open article, or none):
Check name from the table:
Result: not run
```

Recorded runs: none.
