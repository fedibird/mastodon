# Emoji mutes (P2)

Tracking: [#761](https://github.com/fedibird/mastodon/issues/761) /
[#763](https://github.com/fedibird/mastodon/issues/763). P3 is
[#764](https://github.com/fedibird/mastodon/issues/764).

P2 stores one person's mute rules and applies two of the four effects:
`reject_reactions_to_own_posts` and `hide_reactions`. `replace_in_text` and
`hide_in_picker` are saved and returned, and this release does not apply
them. `emoji_mutes` is not added to `fedibird_capabilities` or to
`fedibird.rest.supported` until all four effects are applied.

Deleting a rule deletes only that rule. It does not change a personal emoji
set, a custom emoji, a status, or an existing reaction.

## Storage

`emoji_mutes` is one row per owner and emoji identity. `emoji_mute_collections`
is one monotonic `revision` per user. Neither table is `statuses` or
`status_stats`. Creating or deleting a rule does not scan posts or mark
reaction caches dirty.

| Kind | Identity | What is not the identity |
| --- | --- | --- |
| Unicode | Finished catalog `native` | Variation-selector alias, shortcode, image |
| Local custom | `custom_emoji_id` | Shortcode. A later row with the same shortcode is a different emoji. The stored shortcode is only the label captured at save time. |
| Remote custom | Normalized domain plus shortcode | Cache id. Deleting the cache row does not delete or retarget the rule. |

There is no foreign key to `custom_emojis`, so deleting a cache or local row
does not delete the rule. A read never calls `ResolveURLService` and never
inserts a custom emoji. An unavailable target can still be listed, edited,
and removed.

Partial unique indexes stop a second row for the same owner and identity.
The cap is 500 rules. The JSON body cap is 512 KiB. Replacement text is at
most 32 graphemes and 256 bytes, may be empty, and rejects ASCII control
characters. The default replacement is `［絵文字］`. Unknown JSON fields are
rejected.

An empty replacement is stored as an empty string. A rule whose four effects
are all false stays stored and matches nothing. It is an explicit inactive
rule, not a deletion.

## API

Authenticated. There is no owner id. Another person's id is a 404.

| Method and path | Scopes | Result |
| --- | --- | --- |
| `GET /api/v1/fedibird/emoji_mutes` | `read` or `read:mutes` | `{revision, effect_application, emoji_mutes}` |
| `POST /api/v1/fedibird/emoji_mutes` | `write` or `write:mutes` | 201 and the created rule |
| `PATCH /api/v1/fedibird/emoji_mutes/:id` | `write` or `write:mutes` | The updated rule |
| `DELETE /api/v1/fedibird/emoji_mutes/:id` | `write` or `write:mutes` | `{revision}` |

`POST` body is `{emoji, effects?, replacement?}`. Omitted effects are all
true. Omitted replacement is `［絵文字］`. Explicit `false` and `""` are
stored. `emoji` uses the P1 reference: `{kind, native}`,
`{kind, scope: "local", custom_emoji_id and/or shortcode}`, or
`{kind, scope: "remote", domain, shortcode}`. A local shortcode is pinned to
the current database id. A disabled local emoji can be muted. A missing
remote cache is `detail.state: "unfetched"`.

`PATCH` body is `{expected_revision, effects?, replacement?}`. Omitted
effect keys and an omitted replacement stay as they are. `expected_revision`
is the rule's revision as a string. `If-Match: "<id>-<revision>"` is the
same check. If both are present they must agree. A mismatch is HTTP 409
`code: "conflict"` and writes nothing. A duplicate create is HTTP 409
`code: "duplicate"`. Invalid input is HTTP 422 `{error, errors: [{path, code}]}`.

Every response is `Cache-Control: private, no-store`. The collection `ETag`
is `W/"emoji-mutes-<revision>"`. `If-None-Match` returns an empty 304.
Clients keep the document in memory. Do not put the token or the rule list
in `localStorage`.

`effect_application` is `{applied: ["reject_reactions_to_own_posts", "hide_reactions"], stored_only: ["replace_in_text", "hide_in_picker"]}`.
Detail objects do not include image URLs. P3 must not paint a glyph from
this payload before the person chooses to reveal the list.

A successful change publishes `emoji_mutes_changed` on the owner's
`timeline:<account_id>` stream with `{revision}` only. The event contains
no emoji and no rule. Redis failure does not roll back the save.

`POST /api/v1/fedibird/emojis/resolve` reports `actions.mute.allowed: true`
with the same applied and stored-only lists. `request_registration` stays
`not_implemented`.

## Who is filtered

`reject_reactions_to_own_posts` uses the local user who owns the status the
reaction row is stored on. That is `EmojiReactionCapability::WriteTarget`
plus the one reblog step `EmojiReaction` applies in `before_validation`.
With canonical writes off, a boost URL still consults the boosted status's
author, not the boost author. A remote author is never guessed. An anonymous
request has no hide rules.

`hide_reactions` uses the authenticated viewer. It does not change the
shared cache or a `Status` instance. Serializing the same status for viewer
A, viewer B, then nobody reuses no viewer-specific count.

Unicode rules keep the finished native and match that string exactly in
Ruby, SQL, and the WebUI. A variation selector is a different rule.
`‼` does not match `‼️`, and `1⃣` does not match `1️⃣`.

## New reactions

`EmojiReactionService` and `ActivityPub::Activity::Like#process_reaction`
call `EmojiMutes::ReactionPolicy` before insert, notification, distribution,
delivery, forward, relay, friendship, and moderation. REST raises
`Mastodon::NotPermittedError` (`403`, `This action is not allowed`) and does
not include the rule list. ActivityPub returns normally and does not send a
`Reject`. Favourite `Like` activities are unchanged.

An existing row is not deleted. REST repeat `PUT` with idempotent retry off
does not run notification, delivery, or friendship again while the mute
matches the request identity or the stored row. The legacy boost miss
(canonical writes off, lookup on the boost id) still raises
`RecordInvalid` or `RecordNotFound` instead of becoming a successful no-op.
ActivityPub redelivery of a muted row does not repair the moderation ledger.
`DELETE` and `Undo` still remove the row.

## Groups, cache, and rollback

`status_stats.emoji_reactions_cache` stays a JSON array of name groups.
`emoji_reactions_count` on that row stays the unfiltered total. No backfill
rewrites existing rows. New refreshes add `parts` inside each group:

```json
{
  "name": "blob",
  "count": 2,
  "account_ids": ["1", "2"],
  "parts": [
    {
      "identity": { "kind": "custom", "scope": "local", "custom_emoji_id": "10" },
      "custom_emoji_id": "10",
      "account_ids": ["1"],
      "count": 1
    },
    {
      "identity": { "kind": "custom", "scope": "remote", "domain": "remote.example", "shortcode": "blob" },
      "custom_emoji_id": "11",
      "account_ids": ["2"],
      "count": 1
    }
  ]
}
```

The name, representative image, and account list stay the compatibility
fields. `parts` is how a viewer removes one identity from a mixed name.
Hiding the representative domain does not hide the other identities. After
a hide, the representative is the minimum remaining `custom_emoji_id`.

Reads do not repair a dirty cache. A legacy group with no `parts` is not
hidden from its representative. A Unicode-only legacy group (no `domain`,
`url`, or `static_url`) can be matched by name. Any other legacy group is
filled from `emoji_reactions` for every such status on the page, including
reblogs already loaded with it. The read is chunked by
`EmojiMutes::IdentityBreakdown::QUERY_BATCH` (200 ids) so a context of
thousands of posts does not run one query per post or one unbounded `IN`.
A chunk boundary never leaves a status unfiltered. The read does not write
the cache.

Refresh still holds the `status_stats` row lock, so a newer reaction cannot
be overwritten by an older `dirty=false`. The locked row's previous cache
is passed into the rebuild. If a part's custom emoji row is gone, the
previous part's identity for that id is kept. Rollback to code that does
not know `parts` still reads `name`, `count`, and `account_ids`. It may
also pass `parts` through to clients. It will not apply viewer mutes.
Deploy forward does not need a `status_stats` rewrite.

REST `emoji_reactions` and `emoji_reactions_count` are one projection, so
the count does not depend on which attribute is rendered first. The count
is the visible group total for that viewer. The column used by trends stays
the stored total. `emoji_reactions_cache_token` is the stat `updated_at` in
`YYYYMMDDHHMMSSNNNNNNNNN`. Authenticated statuses also include
`emoji_mutes_revision`.

The public and home reaction stream stays viewer-independent. The payload
adds `parts` and `cache_token` and does not contain a mute list. A client
ignores an event whose `cache_token` is older than
`emoji_reactions_cache_token`. If `emojiMutes.rules` is loaded, the reducer
removes hidden identities before merging. A status import whose
`emoji_mutes_revision` is older than the copy already stored keeps the
stored groups and count.

## Notifications, push, and mail

`hide_reactions` removes matching emoji-reaction notifications in SQL before
`LIMIT`, for the index and the unread count. A page whose rows are all
hidden still returns the next visible rows, and the unread count uses that
same scope. `GET /api/v1/notifications/:id` is 404 while the row is hidden.
The row remains, so deleting the rule shows it again. A reaction that was
never accepted is not recreated.

The reaction-author index uses the same SQL before pagination.
`NotifyService` still inserts the notification, then skips the live stream,
Web Push enqueue, and mail enqueue while the rule matches. Push delivery and
`NotificationMailer.emoji_reaction` check again immediately before send, so
a rule added after enqueue does not reveal the emoji. A rule removed before
that send allows a message that was already queued.

## P3 handoff

P3 applies `replace_in_text` and `hide_in_picker`, builds the settings
screen, and only then advertises `emoji_mutes`.

The signed-in WebUI loads `GET /api/v1/fedibird/emoji_mutes` when the user
stream connects and keeps the document in memory. `observedRevision` is the
newest `emoji_mutes_changed` value. `appliedRevision` is the document that
was stored. Reaction events and anonymous `status.update` payloads wait
until the applied revision has caught up with the observed one. A REST
status whose `emoji_mutes_revision` is older than that applied revision is
not shown as-is, even when the status was not cached yet. The same is true
while `observedRevision` is ahead of `appliedRevision`: a payload stamped
with the older applied revision is not shown until the new document
arrives. Its text is imported. Its reactions are projected with the applied
rules, or omitted when that is not possible, and the stored revision is
not moved backwards. Applying an older mute document does not lower a
status revision that is already newer.
A failed or older mute fetch does not mark the document current. The event
is registered for both WebSocket and EventSource (`KNOWN_EVENT_TYPES`).
After a successful fetch the client does not request every loaded status.
A document with no new hidden identity, including the first empty fetch and
a reconnect of the same revision, issues no status request. Removing a
hidden identity refetches at most 40 statuses that are behind that
revision: the open thread and the head of each column, 20 ids per
`GET /api/v1/statuses?ids[]=`. The notification page is requested at the
same time, with the same `exclude_types` as the notification column, and
is merged into the loaded pages. A failed notification request does not
clear the list. A newer reload is not overwritten by an older one that
finishes later. A status that scrolls into view later, or is opened in
detail, is restored on its own if its revision is still behind. A group
whose projected count is zero is removed. The representative image is
taken from the remaining parts. Do not use `localStorage`.

A status payload whose `emoji_mutes_revision` is older than the copy already
stored keeps that copy's reactions. The rest of the payload, including
edited text, is imported. An anonymous payload has no revision: it is
projected with the applied rules when those rules are current, and otherwise
keeps the previous reactions. Optimistic Unicode and remote adds skip when
those rules are loaded. A local custom optimistic add cannot be matched by
shortcode, because the identity is the database id. The authenticated status
response is authoritative.

Unmuting shows existing reactions and notifications. It does not invent a
reaction the server refused. Personal sets, post source, and the shared
custom-emoji catalog stay unchanged.
