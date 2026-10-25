# Asynchronous RSS unsubscribe

Issue #575. Removing an RSS/Atom subscription used to delete every projection
of the subscription inside the HTTP request, in one transaction. A subscription
with tens of thousands of items timed the settings page out. The request now
only **accepts** the removal and stops new items; the physical delete runs in
Sidekiq in small transactions and its progress is shown to the owner.

## Request path (`ExternalBridge::RSS::Unsubscribe`)

One short transaction, holding the subscription row `FOR UPDATE`:

1. The subscription's `external_feed_routes` are deleted. Every home/list read
   (`Feeds::Query`) and every streaming membership query joins the routes, so
   the items disappear from both at once.
2. `external_subscriptions.state` becomes `deleting` (the fence).
3. An `external_subscription_deletions` row is written (`queued`, with the
   route destinations kept in `route_targets` and `next_run_at` as the durable
   outbox).

The `subscription_removed` streaming event is not registered inside that
transaction. Rails 6.1 raises an `after_commit` exception into the caller after
the database commit, which would answer HTTP 500 for an unsubscribe that had
already been accepted and would skip the deletion enqueue. After the commit,
`SubscriptionRemovedNotice` pushes the event and
`SubscriptionDeletionDispatch` pushes the deletion job. Neither is allowed to
raise, including a database error while recording the push. `control_enqueued_at`
is set only when Sidekiq returns a job id, or when there is no destination.
A nil job id leaves it null. The deletion job tries again, and the recovery
scheduler keeps trying for one day after the request, including after the
deletion is `completed`. A second send is safe.

A connected WebUI that misses the event keeps items it has already drawn until
a reload, a reconnect, or the per-status deletes from the purge. Reload and
reconnect read membership from the routes, which are already gone, so they do
not show those items. The event is best effort. The fence is not.

A refused deletion push or a crashed web process leaves a `queued` row that
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
- `ProjectionPurge.purge_ids_in_transaction!(schedule_deletes: false)`: E4
  `LinkSharing::Retire`, physical `DELETE` under `SET LOCAL
  fedibird.projection_status_delete`, and link-boost state. It does not
  enqueue `StreamDeleteWorker`. In the same transaction the runner inserts one
  `external_subscription_deletion_effects` row per deleted status id. A
  personal projection stores a null `destinations` (cache and search only).
  An external projection stores the home/list destinations from
  `route_targets`, because the routes were removed at accept time.
  `RemoveStatusService`, `discard`, and ActivityPub Delete are never used;
- add the rows the `DELETE` really removed to `deleted_count`, in the same
  transaction.

The transaction then commits. Wrapper removals, cache deletes, search
deletes, and the stream-delete enqueue run after that. Each effect row is
stamped on its own: `cache_cleared_at`, `search_cleared_at`, and, only when
destinations are present, `stream_enqueued_at` after Sidekiq returns a job
id. A cache error does not skip search. A job id does not delete the effect
row while cache or search is still open. The row is deleted only when every
required stamp is set. A nil job id is not acceptance.

Inserts are new rows. The deletion row is not rewritten with a growing JSON
document. While 1000 effect rows are still open (`EFFECTS_CAP`), the runner
does not delete another batch. A refused `perform_async` therefore stops at
about one thousand open rows, not at the size of the subscription. When the
enqueue starts succeeding, those rows drain and deletion continues.

A worker killed after the commit still has every deleted status id, including
personal projections that never needed a stream event. The next run clears
cache and search from those rows. Pushing a stream delete twice is safe:
`StreamDeleteWorker` publishes only when the status and the marker are gone.

The subscription row is not destroyed while any effect row is open. The card
stays under 100% and the record stays `running`, with `next_run_at` 30
seconds out. The worker queues itself for then. That wait does not increment
`attempt_count`. If the queue push is lost, the scheduler sees the same
`next_run_at` and pushes the record again.

A one-shot purge (`purge_status!`, account deletion) still registers
`StreamDeleteWorker` with `AfterOuterCommit`. The callback swallows a Redis
error so it cannot skip cache and search, and so it cannot abort the rest of
account deletion. That path has no outbox: a refused enqueue is not retried.
The batched unsubscribe is the path that deletes tens of thousands of rows,
and it is the path with the outbox.

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
| Exception in a batch | The batch transaction (delete, counter, and effect rows) rolls back. The record becomes `failed` with a fixed `last_error_code` (`database_error`, `queue_error`, `unexpected_error`; never a message) and `next_run_at` backed off 30 s, 2 min, 10 min, 30 min, 2 h. While `next_run_at` is set the scheduler retries by itself: the card shows "waiting to retry", keeps polling, and offers no button (`retrying: true`, `retryable: false` in the API). When it is due the scheduler turns the record into `queued` and pushes it. After 5 attempts `next_run_at` is null; only then does the card stop polling and offer the owner's retry (`retryable: true`); the API accepts a retry only in that state too |
| Cache, search, or stream enqueue fails after the batch committed | The delete and the counter stay. The record stays `running` and `attempt_count` does not move. Only the step that succeeded is stamped. The subscription is not destroyed until cache, search, and any due stream enqueue have all been stamped. Open effect rows are capped at 1000; further deletes wait |
| Late or duplicate job for a `failed` or `completed` record | Ignored: the runner starts only `queued`/`running` records. A `failed` record is moved to `queued` by the scheduler (when due) or by the owner's retry (terminal only), never by a stale job |
| Worker killed | The record stays `running`. `next_run_at` is a 5 minute lease the scheduler honours, then the job resumes where the database says. Effect rows already committed are finished (cache, search, and stream). A batch that had not committed is deleted again. Personal projections are in those rows too, with null destinations |
| Sidekiq push refused | The record stays `queued`; the scheduler pushes it |
| Owner retry | `POST .../subscription_deletions/:id/retry` (API) or the card's button; only a `failed` record moves |
| Feature flags off | The job still finishes; imports stay stopped by the fence |
| User deleted | The progress record cascades; a late job finds nothing and exits |

Completed records are removed after 30 days by the same scheduler.

### Undo of an announced wrapper

`Retire.end!` commits the boost as `undone` and the wrapper as discarded in the
batch transaction, and the wrapper id goes to the E4 worker
(`ExternalBridge::LinkWrapperRemovalWorker`) only after that commit. A crash or a
Redis failure between the commit and `finish_purge!` loses that push, not the
rows, and `end_orphans!` does not help (it looks for `active` rows without a
marker).

`LinkWrapperRemovalWorker` is E4's own entry. Mastodon's `RemovalWorker` is
unchanged, so an explicit request for the same status (`immediate: true` from an
admin or a report decision, a redraft) is never swallowed. The E4 worker is the
only writer of `external_projection_link_boosts.removal_acknowledged_at`, which it
sets when `RemoveStatusService` returned for the wrapper: the Undo has been
handed to ActivityPub delivery, whose own workers retry. It is not the existence
of the wrapper: Mastodon keeps a wrapper that sits in an unresolved report
(`reported?`: discarded, not destroyed, unless `immediate`), and this feature does
not change that (no `immediate`, the report evidence stays). Accepted by Sidekiq
is not done either; only a returned `RemoveStatusService` is.

Exclusion is a lease on the boost row (`removal_lease_token`,
`removal_lease_until`), not a database session. The worker claims the row with
one conditional UPDATE (ended, not acknowledged, no live lease) and writes its
own token, runs `RemoveStatusService` with no transaction open, then acknowledges
with a second UPDATE that matches the token. Each statement stands alone, so the
exclusion does not need both statements to reach the same PostgreSQL backend.
PgBouncer in transaction pooling mode (where a session advisory lock is granted
twice or left behind) and a direct connection behave the same. It is not
`RemoveStatusService`'s Redis lock (`distribute:<id>`), which is released when the
service returns and expires by itself after 15 minutes.

A second job that arrives while the lease is live (5 minutes) does nothing and is
not retried by Sidekiq. The recovery scan also skips a row with a live lease. If
the first job dies, the lease expires and the scan pushes again. A job that fails
gives the lease back before it raises. A job that outlives its lease can be
overtaken; its later acknowledgement matches no token and changes nothing.

Limit: delivery is at least once. A crash between the return of
`RemoveStatusService` and the acknowledgement, or a job that outlives the lease,
lets the next job hand the Undo to delivery a second time. Receivers treat a
repeated Undo as a no-op. Acknowledged means the Undo reached the delivery queue,
not that a remote server received it.

`RSS::RefreshSource` still takes a session advisory lock per source. That predates
this change and is not part of the unsubscribe path. The authoritative check of
a pooler is its admin console: `SHOW CONFIG;` and `SHOW DATABASES;`, column
`pool_mode`. `rake external_bridge:db_session_probe` is a hint only. It takes no
lock and prints no credential. A passing hint is not proof under load.

`LinkSharing::RecoverRemovals`, run by `Scheduler::ExternalBridgeLinkReferencePublishScheduler`
(every 5 minutes), scans `undone` boosts with `wrapper_status_id` still set and
`removal_acknowledged_at` null (a wrapper that never left the server is removed
by `Retire` itself, which nulls the column) and pushes the E4 worker again. The
claim UPDATE repeats the scan's lease predicate (`removal_lease_until` null or
due) and then sets `removal_next_attempt_at` (10 minutes, released at once when
the push is refused). A worker that takes the lease after the scan read the row
makes that UPDATE match nothing, so the scan does not push the hold out while
that worker is still responsible. The claim is separate from `next_announce_at`.
A lost push with no live lease is pushed again within the scheduler period plus
1 minute. The
scan has a partial index (`index_link_boosts_on_pending_removal`, migration
`20261031130000`, built `CONCURRENTLY`) and is not gated by the feature flags.

### Finishing a record

Suppressions are keyed by user and source, not by subscription id, so once the
subscription row is destroyed the same user can subscribe to the same source again
and add suppressions that belong to the new subscription. Every cleanup slice
(suppressions, then item failures) therefore runs in its own short transaction
that locks the deletion row `FOR UPDATE` and checks that the record is neither
`completed` nor `failed`; completion takes the same lock. A worker that was slow
to reach the cleanup either runs a slice before completion (it is still the old
subscription's data) or sees `completed` and deletes nothing.

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
subscription or an unfinished record exists. `20261031130000` adds four nullable
columns (`removal_acknowledged_at`, `removal_next_attempt_at`,
`removal_lease_until`, `removal_lease_token`; no default, no rewrite) and one
partial index on `external_projection_link_boosts` (`CONCURRENTLY`); `down`
drops them. The migration is still unreleased, so the columns were added to the
same file. An environment that already ran the earlier version of it must run it
down and up. `20261031140000` adds nullable `control_enqueued_at` on
`external_subscription_deletions` (no default, no rewrite).
