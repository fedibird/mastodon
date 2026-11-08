# Emoji mutes (P2)

Tracking: [#761](https://github.com/fedibird/mastodon/issues/761) /
[#763](https://github.com/fedibird/mastodon/issues/763).

P2 stores one account's mute rules and enforces two of the four effects:

| Effect | P2 |
| --- | --- |
| `reject_reactions_to_own_posts` | Enforced on new local REST and ActivityPub `Like` / `EmojiReact` rows |
| `hide_reactions` | Enforced for the authenticated viewer on reaction groups, reaction lists, notifications, unread counts, and delayed push/email |
| `replace_in_text` | Stored only. Status text, edit source, and federated content are not rewritten |
| `hide_in_picker` | Stored only. Pickers and the shared custom-emoji catalog are not filtered |

`actions.mute` on `POST /api/v1/fedibird/emojis/resolve` reports that split.
`emoji_mutes` is not added to `fedibird_capabilities` or `fedibird.rest.supported`.
NodeInfo, ActivityPub actor capabilities, and the Mastodon version are unchanged.

Deleting a rule deletes only that rule. Personal-set documents and existing
reaction rows stay as they are. A reaction that was refused is not recreated
when the rule is removed.

## API

`GET/POST /api/v1/fedibird/emoji_mutes` and `PATCH/DELETE /api/v1/fedibird/emoji_mutes/:id`.

There is no account id parameter. Reads accept `read` or `read:mutes`. Writes
accept `write` or `write:mutes`. No new OAuth scope is introduced. Another
account's id is 404. Responses are `Cache-Control: private, no-store`.

```json
{
  "revision": 3,
  "emoji_mutes": [
    {
      "id": "1",
      "revision": 1,
      "emoji": { "kind": "unicode", "native": "👍🏽" },
      "effects": {
        "replace_in_text": true,
        "reject_reactions_to_own_posts": true,
        "hide_reactions": true,
        "hide_in_picker": true
      },
      "replacement": "［絵文字］",
      "availability": "available"
    }
  ]
}
```

Create defaults are all four effects `true` and replacement `［絵文字］`.
Omitted create fields use those defaults. A PATCH changes only the fields it
sends. All four effects `false` is kept; it does not delete the row and it
does not hide or reject. An empty replacement is allowed. The replacement is
plain text: this API does not escape or render it.

Limits: 500 rules per account, 32 Unicode scalars and 128 bytes for
`replacement`, and 8 KiB of JSON. Unknown fields, non-booleans, and a
non-integer `expected_revision` are HTTP 422 `{error, errors: [{path, code}]}`.
A duplicate identity or a stale `expected_revision` is HTTP 409. `If-Match`,
when sent, must match the item ETag `W/"emoji-mute-<id>-<revision>"`. The
collection ETag is `W/"emoji-mutes-<account id>-<revision>"`. `If-None-Match`
on `GET` returns 304.

The collection `revision` increases on every create, update, and delete.
Clients discard a mute document whose revision is older than the one they
already applied. The user stream event is `emoji_mutes_changed` with
`{revision}` only. It does not carry emoji definitions or tokens, and clients
must not put either into `localStorage`.

Reads do not call `ResolveURLService` and do not insert emoji rows.

### Identity

| Kind | Stored identity | Create rule |
| --- | --- | --- |
| Unicode | Finished `native` | Must be in the server Unicode catalog |
| Local | `custom_emoji_id` | The row must exist and be local. A shortcode-only create pins the current id |
| Remote | Normalized domain + shortcode | Cache row optional. No fetch and no local copy |

Unicode comparison does not strip U+FE0E or U+FE0F. `‼` and `‼️` are different
rules and different reaction names, even when the catalog gives them one emoji
id. A later local row with the same shortcode is a different id and is not
muted. A remote cache delete does not retarget the rule; `availability`
becomes `unfetched` and a later cache row with the same domain and shortcode
matches again. A reaction whose custom emoji row has already been deleted is
not guessed back onto a remote rule, because the domain is gone. `detail.cache_id`
is display-only and is absent when nothing is cached.

## Reaction rejection

`EmojiMutes::ReactionPolicy` runs only for a new row, after the existing-row
lookup and before insert, notification, fan-out, delivery, forward, relay,
friendship, and moderation.

The author is the account on the status the row is stored against: the
service's write target, then the model's one reblog hop. A boost author's
mutes are ignored. A remote author's settings are not inferred. Canonical
writes, idempotent retry, and the fallback gate keep their previous meaning
when the emoji is not muted.

REST raises the existing generic 403 `This action is not allowed`. The body
does not contain mute rules or the replacement. ActivityPub `Like` and
`EmojiReact` return without creating a row and without a new Reject activity.
An emoji row is not created on that refused path. `DELETE` / Undo still remove
an existing row. A repeat PUT or redelivery of an existing row does not create
another row and does not run notification or delivery again after the author
has turned rejection on, including when idempotent retry is off. Redelivery of
a row that already exists can still repair the moderation ledger; that repair
does not run for a refused create.

## Viewer projection and cache

`status_stats.emoji_reactions_cache` remains the shared cache. New writes are
a JSON array of the same public name groups, plus:

- `v`: `2`
- `max_id`: highest included reaction id, for operators reading the blob
- `parts`: one entry per `custom_emoji_id` (null for Unicode), with that
  part's `account_ids`, `native` or `shortcode`/`domain`, and display fields

The public `name`, `count`, and `account_ids` are still the merge of every
part, and the display fields still come from the minimum `custom_emoji_id`,
which is what `min(custom_emoji_id)` meant before. Old readers ignore `v` and
`parts`. Rolling the app back does not require a cache migration. Rolling the
migration back drops only `emoji_mutes` and `emoji_mute_revisions`.

`Status#grouped_emoji_reactions(account)` copies that blob and, for a viewer
with `hide_reactions`, drops matching parts before merging the name group
again. The representative image is then the minimum remaining custom emoji
id. A name disappears only when every remaining part is empty. Anonymous
callers and viewers with no hide rules still use the previous account-block
and silence filter. A legacy blob has no parts. It is not muted from its
representative domain. The page loader `EmojiMutes::Breakdown.prepare` reads
those statuses in one query, capped at 40 statuses and 2,000 rows. Overflow
is left unfiltered rather than partially muted. That read does not write the
cache and does not mark every status dirty. New reactions still refresh the
one status inside the existing row lock, so an older refresh cannot commit
after a newer one that holds the same lock.

The same `Status` instance can be projected for two viewers. The shared cache
string is not replaced with either result. `emoji_reactions_count` in the
REST payload follows the visible groups for that call, as it did for blocks.
`emoji_mutes_revision` is added only for a signed-in serializer and is viewer
metadata, not a column.

`GET /api/v1/statuses/:id/emoji_reactioned_by` uses the same identity match in
SQL, so pagination does not return hidden rows. Shared and public stream
payloads from `PublishEmojiReactionWorker` stay viewer-independent and include
`parts` when the cache has them.

## Notifications

An emoji-reaction notification is stored even when `hide_reactions` already
matches, so removing the rule shows it again. Index, show (404), and unread
count exclude current matches with one rule load per request. Redis delivery,
web push, and mail are checked again immediately before send, including
`NotifyService#redeliver_existing!` and a push that was queued earlier.
`hide_reactions: false` does not remove old groups or old notifications.

## P3 contract

- Fetch `GET /api/v1/fedibird/emoji_mutes` before the first render that must
  reflect a change made in another session. Do not cache the document or the
  access token in `localStorage`.
- Keep the collection `revision`. Ignore a document, and ignore
  `emoji_reactions` on a status whose `emoji_mutes_revision` is lower than
  that revision when a previous projection is already on screen.
- On `emoji_mutes_changed`, refetch the document if the revision is newer.
  The event is not a full list.
- Apply `replace_in_text` with `replacement` as plain text on display only.
- Apply `hide_in_picker` in every picker. Do not rewrite the shared
  `GET /api/v1/custom_emojis` catalog.
- Stream `emoji_reaction` events are not pre-filtered. Use `parts` when
  present. A custom group without `parts` must not be dropped from the
  representative domain alone.
- After the revision changes, refetch open timelines. Removing a rule shows
  existing rows again; it does not invent reactions that were never stored.
- Advertise `emoji_mutes` only once all four effects are enforced.

The WebUI keeps the rules in memory, filters stream payloads that include
`parts`, and drops a stale status reaction snapshot. It does not yet replace
status text or filter pickers.
