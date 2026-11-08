# Personal emoji sets

The settings editor is available at `/settings/custom_emojis/personal_set`, under
**Custom emoji → Personal set**. It manages one ordered set per user. The saved
definition is separate from the resolved stock consumed by the lightweight
picker. Empty categories and an empty set are valid.

## Adding frequently used emoji

The editor's **Add emoji** picker starts with **Frequently used**. It reads the
saved WebUI usage counts and display limit already included in the settings
page's initial state. Ordering, limits, and default candidates are shared with
the standard WebUI picker. Both Unicode and currently listed custom emoji can
be selected through the existing resolve-and-add flow. Unicode candidates use
the tone currently selected in the add dialog.

Selecting candidates does not record emoji usage or update Nimble's local
history. This list reflects the saved history when the settings page was opened;
reload the page to pick up later usage from another tab. The standard catalog
still loads only when requested. The personal stock picker continues to show
only registered entries, without a frequently-used category.

## Persistence and updates

Migration `20261115120000_create_personal_emoji_sets` adds one JSONB definition
and revision per user, a unique index on `user_id`, and a cascading user foreign
key. No existing user data needs to be backfilled.

`picker_emoji_size` remains the existing scalar `Setting` value. It is not copied
into the JSONB definition or added to `UserPreferences::WriteContract`. The editor
saves the definition and size in the same transaction under a lock on the user
row. That existing row also serializes simultaneous first saves. Other users do
not share this lock.

Legacy writes of this one size setting also take the user lock. They keep their
existing stored value type. The editor writes validated integer sizes as strings,
matching the old Rails form. Its normalized read accepts the existing integer or
numeric-string value and falls back to 22 for an invalid old value.

The size does not enter the cache before commit. Its after-commit callback reads
the latest committed row under the same lock, so an older callback cannot replace
a newer cache value. The user getter reads this one setting directly from its row
and preserves the legacy raw type; it therefore cannot fill the cache with a stale
value after a concurrent save. Other preference cache paths are unchanged.

## Authenticated API

All routes require the current user's OAuth token. There is no owner/user ID
parameter. Read routes accept `read` or `read:accounts`; the update route accepts
`write` or `write:accounts`.

| Method and path | Result |
| --- | --- |
| `GET /api/v1/emoji_sets/personal` | Editor document, including all saved entries and their current availability |
| `PUT /api/v1/emoji_sets/personal` | Atomic replacement of the definition and display size, with conflict guards |
| `GET /api/v1/emoji_sets/personal/stock` | Only resolved stock, definition revision, and shared display size |
| `POST /api/v1/emoji_sets/personal/resolve` | Resolve a candidate before adding it to an editor draft; does not persist anything |
| `POST /api/v1/emoji_sets/personal/categories/:category_id/items` | Append one emoji to an existing category under the same user lock and revision |

### Definition

Category IDs and placement IDs are stable client-generated identifiers. A
placement identifies a particular occurrence of an emoji; it is different from
the Unicode canonical ID or custom emoji database ID.

```json
{
  "id": "favorites",
  "name": "よく選ぶ",
  "heading": { "mode": "emoji", "item_id": "thumb-medium" },
  "items": [
    { "id": "thumb-medium", "kind": "unicode", "native": "👍🏽", "emoji_id": "+1" },
    { "id": "custom-wide", "kind": "custom", "custom_emoji_id": "123456789", "shortcode": "wide_emoji" }
  ]
}
```

Heading modes are `first`, `initial`, and `emoji`. Missing headings default to
`first`. `initial` takes the category name's first Unicode grapheme, so combining
characters and ZWJ sequences remain intact. `emoji` must reference a placement
within that category. The editor resets an explicit reference to `first` when the
user removes that placement; a malformed reference submitted through the API is
rejected.

Unicode strings are validated against trusted server data and stored exactly as
submitted, including tone modifiers, ZWJ and variation selectors. Their canonical
IDs and display/search metadata come from that catalog. No skin modifier is
applied again when rendering or selecting a saved entry.

Custom emoji are pinned by database ID. The resolve request accepts
`{"kind":"custom","shortcode":"wide_emoji"}` and returns:

```json
{
  "item": { "kind": "custom", "custom_emoji_id": "123456789", "shortcode": "wide_emoji" },
  "resolved": {
    "available": true,
    "label": "wide_emoji",
    "image": { "src": "https://example.org/static.png", "animatedSrc": "https://example.org/image.gif", "alt": ":wide_emoji:", "width": 320, "height": 32 },
    "search": ["wide_emoji"],
    "selection": { "id": "wide_emoji", "custom": true, "native": ":wide_emoji:", "colons": ":wide_emoji:" }
  }
}
```

The editor supplies a placement ID after resolution. Unicode candidates can use
the same endpoint with `kind: "unicode"` and `native`. The response is the same
shape, with the canonical Unicode definition and resolved metadata.

A new shortcode reference must be local, enabled, and listed. An explicit
`custom_emoji_id` may also name an enabled local emoji with
`visible_in_picker: false`. The standard picker list and the shared custom
catalog are unchanged. Disabled, deleted, and remote rows still cannot be
added. A previously registered emoji stays in the definition when it is later
hidden or disabled, but it is not selectable. A different emoji later
registered under the same shortcode never replaces a stored database identity.

`POST /api/v1/emoji_sets/personal/resolve` accepts `custom_emoji_id` in
addition to `kind`, `shortcode`, and `native`. A shortcode on that route
remains listed-only. The separate read-only reference API and the one-item
append are specified in [emoji_actions.md](emoji_actions.md). An item added
by explicit id can be saved again through the existing full `PUT`.

### Editor reads and saves

The editor response contains `revision`, `picker_emoji_size`, `categories`,
`stock`, and `resolved_items`. `resolved_items` is an object keyed by placement ID.
Available values contain `available`, `label`, `image`, `search`, and `selection`.
Unavailable values contain `available: false`, a fallback `label`, and
`reason: "unavailable"`; no selectable payload is supplied.

The update body is:

```json
{
  "expected_revision": 4,
  "expected_picker_emoji_size": 22,
  "picker_emoji_size": 32,
  "categories": []
}
```

Both expected values come from the editor's loaded document. A changed definition
or size returns HTTP 409 with `code: "conflict"` and writes nothing. A successful
explicit save advances the set revision, including a save of an unchanged or
empty set. The response contains the complete committed editor document.

Invalid input returns HTTP 422 with `errors: [{ "path": "…", "code": "…" }]`.
The client keeps its draft on validation, conflict, or network failure.

| Bound | Limit |
| --- | --- |
| JSON request body | 512 KiB |
| Categories | 50 |
| Placements in one category | 200 |
| Placements in the complete set | 1,000 |
| Category name | Nonblank after Unicode whitespace trim; 60 graphemes and 1,024 bytes |
| Category/placement ID | 1–64 ASCII letters, digits, `_` or `-` |
| Picker emoji size | Integer 22–48 px |

Placement IDs are unique across the set. Category IDs are unique across
categories. The same emoji may occur in different categories with different
placement IDs. Exact duplicate Unicode strings or duplicate custom database IDs
within one category are rejected; different skin variants remain distinct.

### Stock and freshness

The stock response is `{revision, picker_emoji_size, stock: {categories: [...]}}`.
Stock entries contain `key`, `label`, individual `image`, `search`, and `selection`.
Every category supplies a resolved `heading: {text, image?}`. `text` is the first
grapheme fallback; `initial` mode never includes an image.

The personal picker uses the shared emoji size as its image frame height. Custom
images keep their aspect ratio with a maximum width of 100 px, matching the
standard picker. Very wide images can appear shorter within that frame when the
width limit applies. Known positive image dimensions reserve the frame width
before loading; older records without dimensions use the loaded image's intrinsic
ratio. Unicode images remain square, and category headings stay in their fixed
22 px frame. Vertical keyboard navigation follows the displayed rows, including
wide images, category boundaries, and filtered results.

In touch dialogs, both picker modes and the standard loading placeholder fill
the available dialog width. The standard picker remeasures its category positions
and scroll viewport when its dimensions change, including device rotation.

The representative is resolved from the original saved order/reference before
filtering unavailable items or performing a search. An unavailable representative
uses the name fallback; it does not promote another available item. Image loading
failures use the same fallback in the client.

Referenced custom records are fetched in one bounded database query. Resolution
does not probe remote image storage or fetch the full custom catalog. The browser
handles a missing image. Unicode assets and searchable names are supplied only
for registered placements.

Stock responses use `Cache-Control: private, no-store`, matching the existing
authenticated API policy. The client retains the current document and ETag only
in page memory and explicitly sends `If-None-Match` on each opening; it does not
depend on the browser's HTTP cache. An unchanged stock returns an empty 304 with
the same private, no-store policy. This saves response bytes, not the database
resolution needed to compute the current ETag.

The ETag includes the viewer, resolved response, Unicode catalog version, and
referenced custom records' cache versions. A custom image/metadata/disabled-state
change can invalidate it without changing the definition revision. Editor and
resolve responses are also `private, no-store`.

## Unicode catalog maintenance

The server-only `config/personal_emoji_set_unicode.json` is generated from the
same pinned `emoji_build.js` output, SVG filenames, and Japanese readings already
used by the WebUI. It is never imported into a browser bundle. The generator checks
every asset and preserves canonical IDs from actual Nimble skin variants.

```sh
node script/generate_personal_emoji_set_catalog.js
node script/generate_personal_emoji_set_catalog.js --check
```

Run generation after updating the picker datasets or readings. Japanese readings
retain their existing Google/Mozc BSD 3-Clause attribution in
`app/javascript/mastodon/features/emoji/emoji_unicode_ja_readings.LICENSE`; the
generated server copy derives from that same licensed source.

## Focused verification

```sh
bundle exec rspec spec/lib/personal_emoji_sets spec/requests/api/v1/emoji_sets/personal_spec.rb
bundle exec rspec spec/lib/settings/scoped_settings_spec.rb
node script/generate_personal_emoji_set_catalog.js --check
```

The save specs require real commits and separate database connections. They cover
rollback, stale revisions and sizes, simultaneous first saves, and delayed cache
callbacks. They must run against PostgreSQL; fixture-only contract checks are not
a substitute for those transaction tests.
