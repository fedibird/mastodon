# Asynchronous RSS unsubscribe

Issue #575. Removing an RSS/Atom subscription used to delete every projection
of the subscription inside the HTTP request, in one transaction. A subscription
with tens of thousands of items timed the settings page out. The request now
only **accepts** the removal and stops new items; the physical delete runs in
Sidekiq in small transactions and its progress is shown to the owner.

## Request path (`ExternalBridge::RSS::Unsubscribe`)

One short transaction, holding the subscription row `FOR UPDATE`:

1. `subscription_removed` (E3 control event) is scheduled after the commit,
   with the destinations the routes had.
2. The subscription's `external_feed_routes` are deleted. Every home/list read
   (`Feeds::Query`) and every streaming membership query joins the routes, so
   the items disappear from both at once.
3. `external_subscriptions.state` becomes `deleting` (the fence).
4. An `external_subscription_deletions` row is written (`queued`, with the
   route destinations kept in `route_targets` for the later delete events and
   `next_run_at` as the durable outbox).

Only after the commit is `SubscriptionDeletionWorker` pushed. A refused push or
a crashed web process leaves a `queued` row that
`Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler` (every minute)
pushes again once `next_run_at` has passed.

| Surface | Before | After |
| --- | --- | --- |
| Settings `DELETE .../subscriptions/:id` | 303 after the delete finished | 303 at once; the page shows a progress card |
| API `DELETE /api/v1/external_bridge/rss/subscriptions/:id` | `200 {}` after the delete finished | `202` with the owner's progress record; the same record again for a repeated request or after completion |
| Unknown id, another user, a roommate on the same account | 404 | 404 |
| Pause, resume, restore, destinations, subscribe the same feed while `deleting` | n/a | `409 subscription_deleting` (settings: flash alert) |

## The fence

`deleting` is not `active`, and nothing may move it back:

- `ProjectionWriter.create!`, the refresh of an existing projection, and the
  recording of an item failure run inside `SubscriptionFence.guard!`. It takes
  the subscription row `FOR SHARE` in the writer's own transaction and refuses
  (`Fenced`) when the row is `deleting` or gone. `FOR SHARE` conflicts with the
  request's `FOR UPDATE`, so every write either commits before the fence (the
  job starts after the fence commits and sees it) or starts after it and is
  refused. The state is read under the lock, not from the model the fetch
  started with.
- `Materialize` stops on `Fenced` and reports `ran: false`, so the caller does
  not reconcile a cut-short run.
- `SubscriptionOutcome` writes through `update_unless_deleting!`, a conditional
  `UPDATE ... WHERE state <> 'deleting'`, so a stale model cannot write `active`
  over `deleting`.
- `Subscribe#ensure_subscription!` reads the row `FOR UPDATE`;
  `pause!`/`resume!`/`restore!` go through `owned!` and `transition!`.
  `FeedRoutes::Update` checks after its own lock.
- `Feeds::Query` also excludes `deleting` in its join, so a surviving route
  cannot reveal anything. `RefreshSource` and the scheduler read `.active`.
- E4: `Ownership.assert_canonical!` refuses a new share on a projection of a
  `deleting` subscription, and `Ownership.lock_live_subscription!` is the
  serialization point. `EnsureReference` (before the reference note is created)
  and `Boost#share!` (before the wrapper and boost row are created) call it
  inside their own transaction, after the policy lock, taking the subscription
  row `FOR SHARE` until that transaction ends; `BoostAnnounce` takes it in both
  of its phases, across the enqueue. A share therefore either commits before the
  removal is accepted (the purge retires it) or is refused with
  `subscription_deleting`; no public note, wrapper, or Announce is created after
  acceptance. Lock order is policy, subscription (shared), mapping rows, boost
  rows. `Unsubscribe` and the purge never take the policy row, and nothing that
  holds the subscription row for update waits for a mapping or a boost, so there
  is no cycle. A state read before the transaction (the early
  `assert_canonical!`) is only a fast refusal.

## Job (`SubscriptionDeletionRunner`)

Each batch is one transaction:

- lock the owner's deletion row `FOR UPDATE` (two workers take turns);
- read `BATCH_SIZE` (default 100, `EXTERNAL_RSS_DELETION_BATCH_SIZE`, 10..1000)
  status ids through the indexed `external_subscription_id`, `ORDER BY
  status_id LIMIT n`. No full `pluck`, no full load;
- `ProjectionPurge.purge_ids_in_transaction!`: the existing contract is
  unchanged (E4 `LinkSharing::Retire`, physical `DELETE` under `SET LOCAL
  fedibird.projection_status_delete`, link-boost state, Streaming delete
  capture and `StreamDeleteWorker`). `RemoveStatusService`, `discard`, and
  ActivityPub Delete are never used. Route destinations come from
  `route_targets`, because the routes were removed at accept time;
- add the rows the `DELETE` really removed to `deleted_count`, in the same
  transaction.

Wrapper removals (`RemovalWorker`), cache entries, and search documents follow
the commit (`ProjectionPurge.finish_purge!`), as they do for any purge.

A run stops after `MAX_BATCHES` (50) or `TIME_BUDGET` (20 s) and queues the next
run one second later, so a long delete never holds a Sidekiq thread. The
`pull` queue is used; there is no Sidekiq retry and no unique lock (a held
unique lock would refuse the continuation).

When a batch finds nothing, the job clears suppressions and item failures in
slices, then takes the deletion row and the subscription row `FOR UPDATE`,
checks that no projection is left, and in that transaction removes the residual
suppressions/failures, destroys the subscription row, and marks the record
`completed`. The destroy fires no second `subscription_removed` event (no routes
are left). The public `external_sources`, `external_resources`, and
`external_actors` are never touched, nor are other users' projections,
favourites, or bookmarks, nor ordinary posts.

## Failure and recovery

| Event | Result |
| --- | --- |
| Exception in a batch | The batch transaction (delete and counter) rolls back. The record becomes `failed` with a fixed `last_error_code` (`database_error`, `queue_error`, `unexpected_error`; never a message) and `next_run_at` backed off 30 s, 2 min, 10 min, 30 min, 2 h. While `next_run_at` is set the scheduler retries by itself: the card shows "waiting to retry", keeps polling, and offers no button (`retrying: true`, `retryable: false` in the API). After 5 attempts `next_run_at` is null; only then does the card stop polling and offer the owner's retry (`retryable: true`) |
| Worker killed | The record stays `running`; `next_run_at` is a 5 minute lease the scheduler honours, then the job resumes where the database says |
| Sidekiq push refused | The record stays `queued`; the scheduler pushes it |
| Owner retry | `POST .../subscription_deletions/:id/retry` (API) or the card's button; only a `failed` record moves |
| Feature flags off | The job still finishes; imports stay stopped by the fence |
| User deleted | The progress record cascades; a late job finds nothing and exits |

Completed records are removed after 30 days by the same scheduler.

### Undo of an announced wrapper

`Retire.end!` commits the boost as `undone` and the wrapper as discarded in the
batch transaction, and the wrapper id goes to `RemovalWorker` (which sends the
Undo for an announced share) only after that commit. A crash or a Redis failure
between the commit and `finish_purge!` loses that push, not the rows, and
`end_orphans!` does not help (it looks for `active` rows without a marker).
`LinkSharing::RecoverRemovals`, run by `Scheduler::ExternalBridgeLinkReferencePublishScheduler`
(every 5 minutes), is the recovery: an `undone` boost whose `wrapper_status_id`
is still set has a wrapper that has not been removed (removing it nulls the
column through `ON DELETE SET NULL`; a wrapper that never left the server is
removed by `Retire` itself), so it is pushed to `RemovalWorker` again. A claim in
`next_announce_at` holds the row out for 10 minutes after a push and is released
at once when the push is refused. `RemovalWorker` on a status that is gone is a
no-op and `RemoveStatusService` sends the Undo once per wrapper, so a repeated
push is safe. The scan has its own partial index
(`index_link_boosts_on_pending_removal`, migration `20261031130000`, built
`CONCURRENTLY`) and is not gated by the feature flags.

## Progress API

`GET /api/v1/external_bridge/rss/subscription_deletions` and `/:id`
(`read:statuses`), `POST /:id/retry` (`write:statuses`). Owner only; another
user, a roommate, and an unknown id are all 404.

```json
{
  "id": "12", "subscription_id": "34", "state": "running",
  "preparing": false, "total": 30000, "deleted": 4500, "remaining": 25500,
  "percent": 15, "eta_seconds": 210, "retryable": false,
  "last_error_code": null, "requested_at": "...", "started_at": "...",
  "finished_at": null, "url": "/api/v1/external_bridge/rss/subscription_deletions/12"
}
```

`total` is counted once, when the job first runs; until then `preparing` is true
and `total`, `remaining`, `percent` are `null`. `deleted` is the number of rows
the database removed. `percent` stays below 100 until `completed`.
`eta_seconds` is `null` until a speed has been observed over at least two
seconds of processing. `retrying` is true for a `failed` record that the
scheduler will retry by itself (`next_retry_at` says when); `retryable` is true
only when no automatic retry is left. The record holds no feed URL, title, text, token, or
exception message.

## Operations

Log lines (`[ExternalBridge::RSS::Deletion] event=... job_id= subscription_id=
user_id= batch= deleted= total= remaining= attempt= elapsed_ms=`) carry only
integers, fixed words, and exception class names.

To tune the load, set `EXTERNAL_RSS_DELETION_BATCH_SIZE`. Look at
`external_subscription_deletions` for `failed` rows and at
`external_subscriptions` rows in `deleting` without a recent
`external_subscription_deletions.last_progress_at`.

## Migration

`20261031120000_create_external_subscription_deletions` replaces the state
`CHECK` of the small `external_subscriptions` table (`NOT VALID`, then
`VALIDATE`, under a 5 s `lock_timeout`) and creates
`external_subscription_deletions`. It does not touch `statuses` or
`external_status_projections`. `down` refuses to run while a `deleting`
subscription or an unfinished record exists. `20261031130000` adds one partial
index on `external_projection_link_boosts` (`CONCURRENTLY`, `down` drops it).
