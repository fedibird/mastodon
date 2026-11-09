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
| Reaction chip | Add / remove reaction | Long-press / ContextMenu / Shift+F10 on the chip itself (no `⋯`). Menu leads with “React with this emoji” / remove |
| Personal stock picker | Insert / select | Long-press always; per-cell `⋯` only in **Edit** mode |
| Standard Nimble picker | Insert / select | Long-press always; per-cell `⋯` + bottom bar only in **Edit** mode; ContextMenu / Shift+F10 use the event cell only |
| Emoji detail (custom + Unicode) | — | Explicit actions button + long-press on preview |

Reaction chips never show a manage `⋯` (including while a picker is in edit
mode). Remote→local copy inference is out of scope here; tracked in #772.

### Picker edit mode

`EmojiPickerShell` owns `editMode` for standard and personal modes. Closed →
reopen always starts in normal mode. **Edit** / **Done** is always shown
(including single-mode hosts). Short-press insert works in both modes.
Hidden `⋯` controls are not rendered (not `opacity: 0`).

### Long-press

`attachLongPressGesture` opens the shared menu without insert / react /
navigate. Move, multi-touch (including a second finger on another element),
and cancel abort. A following synthetic pointer click (`detail >= 1`) is
suppressed for that gesture only; keyboard/accessibility clicks (`detail === 0`)
are never suppressed. Hosts must not keep a sticky “long-press opened” flag
that depends on a React `touchend` the gesture already stopped.

### Copy

Menu offers **Copy emoji** for Unicode (`native`) and local custom
(`:shortcode:`). Remote custom never shows the item. Local id-only refs need a
resolved shortcode before copy is offered.

Mute/unmute in-flight writes are locked by stable identity across menu
close/reopen (separate from post-success sync retry).

Reaction groups use the **display representative** part (group `url` /
`domain`, else minimum `custom_emoji_id`), not `parts[0]` created_at order.
Local identity equality requires both sides to have a stable
`custom_emoji_id` — shortcode alone never matches.

Deferred to P3-B/C wiring (listed so review can track coverage): status
body/CW custom-emoji click (still opens custom detail only), display name,
profile fields, notifications, search results, frequently used / pinned
candidates, compose portable / reaction dropdown beyond shell, touch modal
extras, Rails form picker, personal-set editor standard picker preview
(shell already has Edit), reaction filter picker, autocomplete. Long-press and
shared-menu wiring for those surfaces stay on #764 P3-B/C.

Menu items follow the resolve payload. Missing `actions` (resolve failure)
never implies allow — mutating items stay hidden and **Try again** is offered.
Copy of a finished Unicode / known local shortcode may still be offered.

- Detail (custom route or `/emoji_detail/unicode/:native`)
- Copy emoji (Unicode / local only)
- Mute / unmute / open mute settings (no registration request — P4)
- Add to each personal category when `add_to_personal_category.allowed`
- Duplicate category appends stay idempotent (200 `added: false`); 409/422
  are shown without wiping the personal set
- Reaction source only: first item toggles the same reaction via existing
  add/remove path (disabled when at limit / reactions disabled, other items stay usable)

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
- After an explicit “Show preview”, resolve (or the Unicode native) paints a
  real preview when obtainable; missing/disabled images stay unavailable
- Edits commit on “Save changes” with `expected_revision` + `If-Match`
- 409 keeps dirty edits and offers reload of the saved baseline
- Rules for deleted / disabled / unfetched targets remain editable

## Capability

Do not add `emoji_mutes` to `fedibird_capabilities` or
`fedibird.rest.supported` until P3-D.
