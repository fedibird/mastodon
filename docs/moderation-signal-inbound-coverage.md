# Moderation signal — inbound ActivityPub coverage audit (PR 6)

- Status: audit + first inbound hooks
- Scope: record remote-actor → local-target interactions/rejections that were
  previously observed only from the local side, closing the "remote actor looks
  inactive" gap in evidence snapshots.
- Non-goals: scoring, enforcement, inferring remote-server-internal state.

## Why this matters

Until now the ledger only recorded interactions initiated through **local**
services (`FollowService`, `FavouriteService`, `EmojiReactionService`,
`BlockService`, …). Inbound ActivityPub activities bypass those services and
create their records directly, so a remote abuser who mass-follows / favourites
/ reacts to local accounts and then gets blocked or reported would show up in a
snapshot with `blocks_received`/`reports_received` > 0 but `unique_contacts`
= 0 — i.e. "did nothing, but was blocked". Recording the inbound contacts fixes
that asymmetry.

## Idempotency mechanism (reused, not changed)

`Moderation::EventRecorder` dedupes via `source_event_key`
(`"#{Model.base_class.name}:#{id}:#{event_type}"`) + a unique index and an
`upsert_by_source_key` guard. Every inbound hook passes the **created record**
(`Follow`/`FollowRequest`, `Favourite`, `EmojiReaction`, `Block`) as
`source_record`, so ActivityPub re-delivery / retries never double-record, and
the key space does not collide with the local-side hooks (which act on
different records).

## Inbound path audit

| Activity | Record | Creation site | Prior coverage | PR 6 |
|---|---|---|---|---|
| Follow (remote → local) | `FollowRequest` / `Follow` | `activity/follow.rb` `FollowRequest.create!` (both the gated and auto-accept branches originate here) | none (`AuthorizeFollowService`/`follow!`, not `FollowService`) | **hooked** → `follow` |
| Like → favourite (remote → local status) | `Favourite` | `activity/like.rb#process_favourite` `favourites.create!` | none (not `FavouriteService`) | **hooked** → `favourite` |
| Like/EmojiReact → reaction (remote → local status) | `EmojiReaction` | `activity/like.rb#process_reaction` `emoji_reactions.create!` | none (not `EmojiReactionService`) | **hooked** → `reaction` |
| Block (remote → local) | `Block` | `activity/block.rb` `@account.block!` | none (not `BlockService`) | **hooked** → `block` (rejection) |
| Flag (remote → local) | `Report` | `activity/flag.rb` → `ReportService` | covered | — |
| Create → reference (remote → local status) | `StatusReference` | `activity/create.rb` → `ProcessStatusReferenceService` | covered (non-quote) | — |
| Create → mention (remote → local) | `Mention` | `activity/create.rb` `attach_mentions` (`ProcessMentionsService` is local-only) | none | **hooked (PR 6b)** → `mention` |
| Create → reply (remote → local) | `Status#in_reply_to_account_id` | `activity/create.rb` thread resolution | none | **hooked (PR 6b)** → `reply` |
| Create → quote (remote → local) | `Status#quote_id` | `activity/create.rb` (PSR skips quote) | none | **hooked (PR 6b)** → `quote` |
| Accept (remote accepts local follow request) | `Follow` | `activity/accept.rb` → `follow!` | intentionally skipped | — (already recorded at local request time; recording here would double-count the same logical follow) |
| Reject (remote rejects local follow request) | destroys `FollowRequest` | `activity/reject.rb` `reject!` (not `RejectFollowService`) | none | **deferred** (`follow_reject`) |
| Announce (remote boost of local status) | reblog `Status` | `activity/announce.rb` | n/a | out of ledger's event set |

Notes:
- Inbound favourite/reaction/follow/block always target a **local** account
  (the activity classes early-return unless the target/status owner is local),
  so hooks are guarded on `local?` where the target is a status owner.
- Inbound block on `block.rb` may also call `RejectFollowService` when a local
  account had a pending follow request to the remote actor; that path already
  records a `follow_reject` and is unchanged here.

## Coverage metadata

`ModerationEvidenceSnapshot` fingerprints carry `coverage`. It is now reported
per event type (schema_version bumped 3 → 4):

```json
{
  "inbound_activitypub": "partial",
  "complete_for_remote_subjects": false,
  "observed_inbound_event_types": ["follow", "favourite", "reaction", "block", "report", "reference", "mention", "reply", "quote"],
  "deferred_inbound_event_types": ["follow_reject"]
}
```

`complete_for_remote_subjects` stays `false` until the last deferred inbound
path (follow-request reject) is hooked. Do not read a low remote count as "no
behaviour" while coverage is partial.

## PR 6b — inbound mention / reply / quote

`activity/create.rb#create_status` runs a single chokepoint,
`record_inbound_status_signals`, for both a freshly processed status and a
re-delivery of an existing one (so a re-delivery repairs a ledger event a
transient recorder failure missed):

- **reply** — when the inbound status replies to a local account
  (`in_reply_to_account_id` is local); keyed on `activitypub_reply:<status.uri>`.
- **mention** — for each non-silent mention of a local account, excluding the
  replied-to account (recorded as a reply); keyed on the `Mention` record.
- **quote** — when the inbound status quotes a local account's status; keyed on
  `activitypub_quote:<status.uri>`.

Reply/quote use activity-identity keys (the status URI) so they stay stable and
deduped across re-delivery. Silent (audience) mentions are not recorded.

## Deferred to a follow-up

- Inbound follow-request **reject** (`activity/reject.rb`): the `Reject` bypasses
  `RejectFollowService` and destroys the `FollowRequest`, so a stable key would
  need to derive from the Reject activity id rather than the destroyed record.
