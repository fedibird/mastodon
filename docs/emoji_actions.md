# Emoji references and actions (P1)

Tracking: [#761](https://github.com/fedibird/mastodon/issues/761) /
[#762](https://github.com/fedibird/mastodon/issues/762).

P1 adds a read-only typed reference API and a one-item personal-set append.
Mute storage and registration requests are not implemented. Their actions are
reported as unavailable and are not advertised.

## `POST /api/v1/fedibird/emojis/resolve`

Authenticated read. Accepted scopes are `read` or `read:accounts`. There is no
owner id parameter. The response is `Cache-Control: private, no-store`.

The request is JSON:

```json
{
  "emoji": { "kind": "unicode", "native": "👍🏽" },
  "context": { "status_id": "123", "account_id": "456" }
}
```

`context` is optional. When it is present, each id is loaded with the existing
status and account visibility checks. A missing or hidden target is HTTP 404.
The response never includes the status text or the account.

This route does not fetch a remote URL, copy an emoji, or write the emoji
tables. `ResolveURLService` is not used. An explicit fetch remains
`POST /api/v1/custom_emojis/:id/fetch`. That route retrieves remote detail.
It does not register a local copy.

### Reference

| Kind | Accepted fields | Stable reference |
| --- | --- | --- |
| Unicode | `kind`, `native` | `{kind, native}`. The catalog id is `detail.emoji_id` only, so this object can be sent back to resolve or appended to a category. |
| Local custom | `kind`, optional `scope: "local"`, `custom_emoji_id` and/or `shortcode` | `{kind, scope: "local", custom_emoji_id, shortcode}` |
| Remote custom | `kind`, `scope: "remote"` or a `domain`, plus `shortcode` | `{kind, scope: "remote", domain, shortcode}` |

Unicode `native` is the finished string. Skin tone, ZWJ, variation selectors,
flags, and keycaps are kept. A string that is not in the catalog is HTTP 422
`invalid_unicode`.

A local shortcode is matched exactly, including case, and the response pins
the current database id. After that row is deleted, the same shortcode
resolves to a later row; the old id does not. A shortcode alone never selects
a remote row.

A remote domain is normalized with `TagManager#normalize_domain`. Empty,
illegal, and this server's own domain are HTTP 422 `invalid_domain`. They are
not reread as local emoji. The same shortcode on this server and on another
domain stay different references. Image URLs are unknown fields, not identity.

A cached remote row adds display detail and an auxiliary `detail.cache_id`.
That id is not part of the reference. A missing cache row is
`detail.state: "unfetched"` and does not invent a local emoji or a fetched
image. `custom_emoji_id` together with a remote domain is
`contradictory_field`. A local id that points at a remote row is
`contradictory_scope`.

### Actions

`actions.add_to_personal_category.allowed` is true for catalog Unicode and for
an enabled local emoji, including `visible_in_picker: false`. It is false with
`reason: "disabled"` or `"remote_emoji"` otherwise.

`actions.mute` is `{allowed: true, applied: ["reject_reactions_to_own_posts", "hide_reactions"], stored_only: ["replace_in_text", "hide_in_picker"]}` for every reference this route resolves, including a disabled local emoji and an unfetched remote emoji. `allowed` means a mute rule can be saved. It does not mean all four effects change what a person sees. Text replacement and picker exclusion are stored for P3 and are not applied yet. `emoji_mutes` is therefore not advertised. The mute API is specified in [emoji_mutes.md](emoji_mutes.md).

`actions.request_registration` is always `{allowed: false, reason: "not_implemented"}`.

HTTP 422 uses `{error, errors: [{path, code}]}`. Unknown fields, non-JSON,
and bodies over 512 KiB are rejected. No partial emoji write is possible
because the action does not write.

## `POST /api/v1/emoji_sets/personal/categories/:category_id/items`

Authenticated write. Accepted scopes are `write` or `write:accounts`. The
category id is the caller's existing category id, not a name and not another
user's id.

```json
{
  "expected_revision": 4,
  "emoji": { "kind": "custom", "custom_emoji_id": "123456789" }
}
```

The route locks the same `users` row as `PersonalEmojiSets::Save`, reads the
latest document, and compares `expected_revision` before duplicate detection
and before availability. A mismatch is HTTP 409 `code: "conflict"` and writes
nothing. The same order applies to a first save, a full `PUT`, and another
append.

A matching revision and the same identity already present in that category is
HTTP 200. `operation.added` is false, the existing `item_id` is returned, and
the revision, `updated_at`, and picker size stay unchanged.

A new item is appended at the end. The server chooses a placement id. The
response is the existing editor document plus:

```json
{ "operation": { "added": true, "category_id": "favorites", "item_id": "i0123456789abcdef" } }
```

`GET` and `PUT /api/v1/emoji_sets/personal` do not add `operation`. The saved
category order, other items, heading, unavailable rows, and
`picker_emoji_size` stay as they were. The picker-size setting is not
written, so its after-commit cache path is not invoked. The stock ETag
changes when the document changes because it already covers the resolved
stock. A raised error inside the locked transaction rolls back the append;
revision, size, and stock ETag stay on the previous commit.

Unknown categories are HTTP 404 `code: "category_not_found"`. None are
created. Disabled, deleted, and remote references are HTTP 422 and leave the
document unchanged. A shortcode whose current local emoji is hidden from the
picker is also 422. The explicit database id of an enabled hidden local emoji
is accepted and remains that id if the shortcode is registered again later.

Limits match the editor save: 512 KiB, 50 categories, 200 items in a
category, and 1,000 items in the set.
