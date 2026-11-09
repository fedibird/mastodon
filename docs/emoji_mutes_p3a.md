# Emoji mutes WebUI (P3-A)

Tracking: [#761](https://github.com/fedibird/mastodon/issues/761) /
[#764](https://github.com/fedibird/mastodon/issues/764). Depends on P2
merge `131c3b18e7` (`emoji_mutes` API, revision stream, viewer projection).

P3-A adds the shared actions menu and the mute settings screen. It does
**not** apply `replace_in_text` or `hide_in_picker`, and it does **not**
advertise `emoji_mutes`. Those remain P3-B / P3-C / P3-D.

## Shared actions

`openEmojiActions(reference, context)` opens one menu for a typed P1
reference. Hosts must not duplicate resolve / mute / category logic.

| Host in P3-A | Normal click | Management entry |
| --- | --- | --- |
| Reaction chip | Add / remove reaction | `⋯` button, ContextMenu, Shift+F10 |
| Personal stock picker | Insert / select | ContextMenu, Shift+F10 on the cell |
| Standard Nimble picker | Insert / select | ContextMenu, Shift+F10 on the cell |
| Emoji detail (custom + Unicode) | — | Explicit actions button |

Deferred to P3-B/C wiring (listed so review can track coverage): status
body/CW custom-emoji click (still opens custom detail only), display name,
profile fields, notifications, search results, frequently used / pinned
candidates, compose portable / reaction dropdown beyond shell, touch modal
extras, Rails form picker, personal-set editor standard picker preview,
reaction filter picker, autocomplete.

Menu items follow the resolve payload:

- Detail (custom route or `/emoji_detail/unicode/:native`)
- Mute / unmute / open mute settings (no registration request — P4)
- Add to each personal category when `add_to_personal_category.allowed`
- Duplicate category appends stay idempotent (200 `added: false`); 409/422
  are shown without wiping the personal set

Mute create uses P2 defaults (all four effects on, replacement `［絵文字］`)
and refreshes through `syncEmojiMutes` / `emoji_mutes_changed`.

## Mute settings

Path: **Settings → Custom emoji → Mutes**
(`/settings/custom_emojis/mutes`). Same Rails + pack mount pattern as the
personal set. Not embedded in the WebUI iframe registry in this step
(personal set is also standalone).

- List is collapsed until “Show muted emoji (N)”
- Collapsed and list rows never paint Unicode glyphs, custom images, alt,
  title, or aria text that would reveal the glyph from the mute payload
- Preview control only explains that the mute API omits image URLs
- Edits commit on “Save changes” with `expected_revision` + `If-Match`
- 409 keeps dirty edits and offers reload of the saved baseline
- Rules for deleted / disabled / unfetched targets remain editable

## Capability

Do not add `emoji_mutes` to `fedibird_capabilities` or
`fedibird.rest.supported` until P3-D.
