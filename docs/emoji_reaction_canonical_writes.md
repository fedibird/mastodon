# Emoji reaction canonical writes and idempotent retry (P1b-1a)

Issue: fedibird/mastodon#579. Design: `docs/emoji_reaction_capability_resolver.md` sections 8.3, 10 (7a, 7b), and 11. P1a shadow mode stays as it is (`docs/emoji_reaction_shadow_mode.md`).

This change makes two legacy write bugs optional, each behind its own flag. Both flags ship **off**. Nothing here changes ActivityPub activity types, fan-out audiences, user settings, REST fields, or the database schema.

## What the flags do

| Variable | Default | When `true` |
|---|---|---|
| `EMOJI_REACTION_CANONICAL_WRITES` | unset (off) | Lookup, insert, the remote-custom-emoji availability check, the per-account cap, and undo all use `status.proper` (the original of a boost). `show?` on the URL status is unchanged. A boost also requires `show?` on that original, and `ExternalBridge::Guards.reject_target!` runs on it as well as on the URL status. The REST body is still the URL status. |
| `EMOJI_REACTION_IDEMPOTENT_RETRY` | unset (off) | A `PUT` that finds an existing `(account, write status, name)` row returns success and does not call `NotifyService`, enqueue `DeliveryWorker` or `CustomEmojiDistributionWorker`, bump `PotentialFriendshipTracker` / `ActivityTracker`, or record a moderation reaction. A lost `RecordNotUnique` insert is the same only when the re-read finds that row (including the row `before_validation` stored on the boosted status): no repeated side effects. The insert runs in a savepoint so an outer transaction stays usable. If the row is still missing after 3 attempts, the service raises `Mastodon::RaceConditionError` (HTTP 503). That is not a 200. |

Only the exact string `true` turns a flag on. `1`, `TRUE`, and `on` are off. The value is read from the process environment on each write. There is no `Setting` row.

P1a shadow hooks are unchanged and still run only from the legacy delivery path. A retry that skips that path is not observed. A new reaction is observed exactly when a delivery decision runs, as before.

## Flag matrix

| Canonical | Idempotent | New reaction on a boost | Repeat `PUT` of the same emoji | Repeat `PUT` through the boost while under the cap | Repeat `PUT` through the boost at the cap |
|---|---|---|---|---|---|
| off | off | Row is stored on the original (`before_validation`). Delivery already addresses the original author. | Same status id: success, **side effects run again**. | Misses the row, hits the unique index, `find_by!` on the wrapper id → **404**. | Misses the row, validator counts the original → **422**. |
| on | off | Same stored row and the same delivery type and inbox as off. | Success, **side effects run again**. | Success (lookup hits). Side effects run again. | Success. Side effects run again. |
| off | on | Same as off/off for a new row. | Same status id: success, **no side effects**. | Success. The loser re-reads the original's row. No side effects. | Still **422**. The cap is checked before the unique index, and the lookup key is still the wrapper. |
| on | on | Same delivery as a new legacy reaction. | Success, no side effects. | Success, no side effects. | Success, no side effects. |

Idempotent retry alone does not make a boost repeat succeed once the per-account cap is already reached. Canonical writes alone do not stop a repeat from notifying, delivering, or bumping friendship. Staging that wants both properties turns **both** flags on.

Friendship and the moderation event for a **new** reaction still use the status named in the request (the boost, when the client sent the boost). Delivery and the stored row use the original author, which a successful create already did. That split is the pre-P1b-1a behavior. A later interaction-resolver or audit pass may want them to name the same account. This PR does not change it.

An expired or discarded original is hidden from the `reblog` association, so `reblog?` is false and both the legacy callback and the resolver leave the boost as the target. This does not newly reveal that original.

A hand-built chain longer than 5 boosts, or a cycle, raises `Mastodon::ValidationError` (HTTP 422) when the canonical flag is on. The walk does not stop on an intermediate boost and insert there. With the flag off, `before_validation` still rewrites one step and does not raise.

A 200 from these actions means the reaction row exists, except one pre-existing silent no-op: a remote custom emoji that is not already used on the target status returns 200 and writes nothing (design Q8, unchanged here).

## Extra reads when the canonical flag is on

`authorize_canonical_target!` and each service call `WriteTarget.resolve` separately. For a boost, each call loads the original (`reblog`, then `proper`). One request therefore reads it twice. Count those queries before enabling the flag. The idempotent flag adds a savepoint around the insert and does not add that read.

## What stays on the old path

With both flags unset, `Status#proper` is not called from these services. The SQL, the jobs, and the REST body of a reaction write match the previous services (P1a shadow, when enabled, is still the only added read). `ActivityPub::DeliveryWorker` and `ActivityPub::CustomEmojiDistributionWorker` do not read either variable. A job enqueued by an old or flag-off process still delivers the payload it was given. Fan-out type and audience are unchanged.

Turning the flags on does not change the activity type or the inbox of a **new** reaction, including a boost whose author is not the original author, a missing Node row, a silenced author, or `kmyblue`.

## Staff / staging check

1. Deploy the code with both variables unset. Restart web processes. Confirm a boost `PUT`, a repeat `PUT`, and a `DELETE` match production (the boost repeat may still 422 or 404; that is the old bug).
2. On a staging host, set both variables to `true` and restart **every web process that serves `/api/v1/statuses/:id/emoji_reactions`**. Sidekiq does not need the variables.
3. As a staff account: `PUT` an emoji on an original, `PUT` the same emoji on a boost of that original, `PUT` the original again. Expect one row on the original, one notification, one delivery. `DELETE` and `POST .../unreact/:id` and `POST .../emoji_unreaction` through the boost remove that row. A repeat of an existing emoji at the cap returns 200 and does not enqueue another delivery.
4. Confirm a status the viewer cannot `show?` (block, followers-only, limited, private projection) cannot be written through a boost of it, and that `setting_disable_reactions` still rejects `PUT` with 403 while `DELETE` of an existing row still works.

Do not enable the flags in production until that staging check is recorded. P1b policy and delivery-plan switches are still out of scope and stay off.

## Rollback

Unset both variables (or either one) and restart the web processes. The next request uses the legacy path. No migration runs backward, and no row has to be rewritten. Jobs already on the queue deliver once; they are ordinary legacy payloads. A rolling restart can mix flag-on and flag-off processes: a boost repeat may then 200 on one process and 422 or 404 on another. Prefer one restart of all web processes over a mixed fleet.

## Workers and a mixed fleet

The request process decides the row and, for a remote author, serializes the activity before enqueue. Sidekiq only delivers that JSON, or rebuilds fan-out JSON from the stored row inside `CustomEmojiDistributionWorker`. The worker's own environment does not select a different status or activity type. Setting the variables on Sidekiq has no effect. Unsetting them on Sidekiq is not required for rollback.
