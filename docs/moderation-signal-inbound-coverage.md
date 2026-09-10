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
| Reject (remote rejects local follow request) | destroys `FollowRequest` | `activity/reject.rb` `reject!` (not `RejectFollowService`) | none | **hooked (PR 6c)** → `follow_reject` (rejection) |
| Announce (remote boost of local status) | reblog `Status` | `activity/announce.rb` | n/a | out of ledger's event set |

Notes:
- Inbound favourite/reaction/follow/block always target a **local** account
  (the activity classes early-return unless the target/status owner is local),
  so hooks are guarded on `local?` where the target is a status owner.
- Inbound block on `block.rb` may also call `RejectFollowService` when a local
  account had a pending follow request to the remote actor; that path already
  records a `follow_reject` and is unchanged here.

## Coverage metadata

`ModerationEvidenceSnapshot` fingerprints carry `coverage`. It is reported per
event type (schema_version is now `6`):

```json
{
  "inbound_activitypub": "partial",
  "complete_for_remote_subjects": false,
  "observed_inbound_event_types": ["follow", "follow_reject", "favourite", "reaction", "block", "report", "reference", "mention", "reply", "quote"],
  "deferred_inbound_event_types": [],
  "known_inbound_recording_gaps": [
    {
      "event_type": "follow_reject",
      "shape": "bare_follow_request_uri",
      "condition": "double_recorder_failure",
      "repairable": false,
      "reason": "An ordinary recorder-only failure is repaired on re-delivery by correlating the follow-request URI to the outbound follow interaction (activitypub_follow:<uri>). The event is lost only when both the outbound follow interaction and the inbound reject failed to record, leaving no correlation anchor."
    }
  ]
}
```

**"All modeled types hooked" is not "coverage complete/reliable".** Every modeled
inbound event type now has a record-creation-site hook, so
`deferred_inbound_event_types` is empty. But `inbound_activitypub` stays
`partial` and `complete_for_remote_subjects` stays `false` because one hooked
shape can still lose an event under a rare double recorder failure, tracked
explicitly in `known_inbound_recording_gaps`. Downstream analysis/scoring must
keep using these flags as a guard: while any gap remains, low/zero counts must
not be read as absence of behaviour.

The residual issue is a recording-reliability gap, not a missing event type:

- A `Reject` carrying only the bare follow-request URI is repaired on
  re-delivery after an ordinary recorder-only failure by correlating the
  follow-request URI to the outbound follow interaction (see PR 6d below). It is
  lost only under a *double* recorder failure — when both the outbound follow
  interaction and the inbound reject failed to record — because then no
  correlation anchor persists (`condition: double_recorder_failure`). The
  embedded-`Follow` shape repairs directly from `@object['actor']`, so it is not
  listed as a gap.
- A `Reject` of an already-established follow is modeled as an unfollow, not as a
  follow_reject, so it is intentionally not recorded as a rejection.

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

## PR 6c — inbound follow-request reject

`activity/reject.rb` records a `follow_reject` rejection (rejector = the remote
actor, rejected = the local requester) at every `Reject`-of-follow-request site:

- **embedded-`Follow` shape** (`reject_embedded_follow`): the rejected local
  account is derived from `@object['actor']`, so the hook still records — and
  **repairs a missed ledger event on re-delivery** — after `reject!` has
  destroyed the `FollowRequest`.
- **bare follow-request-URI shape** (`follow_request_from_object`): the local
  requester is captured **before** `reject!` destroys the `FollowRequest`, so it
  is recorded on first delivery. Re-delivery repair for this shape is handled in
  PR 6d below.

Both keep one stable, activity-identity key
`activitypub_follow_reject:<Reject id>` so retries never double-record. A
`Reject` of an already-established follow is intentionally treated as an unfollow
(not a `follow_reject`).

## PR 6d — repairing the bare-URI reject via outbound follow correlation

The bare-URI Reject shape used to be non-repairable: `reject!` destroys the
`FollowRequest`, and its URI is an opaque payload id (`…/<uuid>`,
`FollowRequest#set_uri` → `generate_uri_for`) that does **not** encode the
requester, so a recorder-only failure on first delivery was permanent.

To close the ordinary case, the outbound follow interaction is keyed on the
ActivityPub Follow activity identity in a **direction-specific** namespace:

- `FollowService` records the `follow` interaction with
  `source_event_key = activitypub_outbound_follow:<follow record uri>` (falling
  back to the record-derived key only when no uri is present). The dedicated
  outbound namespace keeps these locally generated anchors from ever colliding
  with inbound follow ids, which are supplied by remote actors and keyed
  `activitypub_follow:<@json['id']>` in `activity/follow.rb`.

On a bare-URI Reject re-delivery, `activity/reject.rb#repair_inbound_follow_reject_from_uri`
looks up `ModerationInteractionEvent` by
`activitypub_outbound_follow:<object_uri>` (the Reject echoes back the
follow-request URI) and recovers the local requester from its `actor_subject`,
then records the `follow_reject` under the stable
`activitypub_follow_reject:<Reject id>` key.

**URI equality alone does not bind identities.** For a moderation evidence
ledger, a leaked/reused/malicious object URI must not let remote actor B cause us
to record "B rejected local A" from an anchor that was actually "A → remote C".
The repair therefore fails closed unless the anchor satisfies every invariant of
the follow this Reject claims to reject:

- `event_type == follow` (enforced in the query);
- the anchor's `actor_subject` resolves to a **local** requester;
- the anchor's `target_subject` is the very remote actor now sending the Reject
  (`target_subject.account_id == @account.id`);
- the source key / URI matches the rejected Follow activity identity.

This is durable correlation, not identity invention: the requester is re-read
from a ledger row tied to the exact same activity URI *and* the same
actor/target identities. The only remaining loss is the **double** recorder
failure (both the outbound follow interaction and the inbound reject failed to
record), so `known_inbound_recording_gaps` narrows to
`condition: double_recorder_failure` and coverage stays `partial` /
`complete_for_remote_subjects: false`.
