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

If the element fires `error`, the `src` is removed and the UI links to the
media URL and, when the projection has one, the article `canonical_url`.
`javascript:` and credential URLs are not used for either link.

Saved images and a saved video stay on the local gallery and the local
player, including picture-in-picture for the saved player. A remote file
uses the browser's native controls. A sensitive or content-warning status
keeps the remote block behind the same overlay as other media. A processing
failure while hybrid mode is copying a video leaves the remote player in
place. That path is covered by the hybrid specs, not by a device.

## Formats

| File | What to expect |
| --- | --- |
| MP4 (`video/mp4`) | Native `<video>` after click. |
| WebM (`video/webm`) | Native `<video>` where the browser supports WebM. |
| HLS (`.m3u8`) | Safari may play it as `src`. Chrome and Firefox do not, because this build does not include an HLS library. The error fallback should appear. |
| MP3 | Native `<audio>` after click. |

Fedibird does not send `HEAD` for these remote files. A publisher that
rejects `HEAD`, returns 403, or ignores `Range` is visible only in the
browser. Seeking then either works, stalls, or fires `error`.

## Not run in this environment

iOS Safari, iOS PWA (standalone), Chrome desktop, Chrome Android, and a
real publisher CDN were not executed here. No row below is a pass.

| Check | iOS Safari | iOS PWA | Chrome desktop | Chrome Android |
| --- | --- | --- | --- | --- |
| Click does not autoplay; `src` appears only then | not run | not run | not run | not run |
| MP4 plays with native controls | not run | not run | not run | not run |
| WebM plays or shows the fallback | not run | not run | not run | not run |
| HLS plays only where the browser supports it, otherwise the fallback | not run | not run | not run | not run |
| Seek / `Range` on a byte-serving MP4 | not run | not run | not run | not run |
| Publisher 403 or redirect shows the fallback, not a second consent screen | not run | not run | not run | not run |
| Sensitive overlay hides the remote block until reveal | not run | not run | not run | not run |
| Image and remote video stay in article order | not run | not run | not run | not run |
| Picture-in-picture on a saved local video | not run | not run | not run | not run |
| Hybrid copy failure still offers the remote player | not run | not run | not run | not run |

## Fixture

`spec/fixtures/external_bridge/playback_feed.xml` is a private RSS item.
Host it and the media files on **https** origins the CSP allows. Point
`<link>` and the enclosure URLs at those files before subscribing. Subscribe
as a tester with `external_bridge_rss` enabled. Expected UI, still subject
to the table above:

1. The image is a local attachment. The three remote files are buttons.
2. The document does not contain the media URLs until a button is clicked.
3. Nothing plays by itself.
4. A click assigns `src` once. A second click is not required to show controls.
5. If the file errors, the player is removed and "Open media file" plus
   "Open article" (`https://example.com/playback-story`) are shown.
6. Collapsing the sensitive warning removes the player and the URLs again.

Jest covers the click, the missing `src`, and the error links only. It does
not play media.
