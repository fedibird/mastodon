# Follow Import dispatch shadow scheduler

Status: infrastructure / observation only (PR A + PR B).
Default: **off**.

This is Stage 1 from `docs/follow_import_dispatch_pacing_design.md`.
A global scheduler tick can take a PostgreSQL session advisory lease,
build an **account-first shadow plan**, and write tick telemetry. It
does **not** dispatch, claim, enqueue, pause, or slow Follow Import
execution.

`FollowImport::BatchExecutionWorker` remains the only real claimer.

## Activation

```bash
FOLLOW_IMPORT_DISPATCH_SHADOW=true
```

Optional diagnostic budget (positive integer; default = current
`FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` / 50):

```bash
FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET=50
```

Exposed as `FollowImport::ExecutionPolicy.dispatch_shadow_enabled?` and
`.shadow_plan_budget`. Do not treat `shadow_plan_budget` as a production
dispatch rate or as the future global budget.

- `false` (default): cheap no-op. No lease, no planning, no cursor, no
  tick row, no Follow Import behavior change.
- `true`: one process may acquire the global lease, inspect work/load,
  build a shadow plan, write `follow_import_dispatch_tick_observations`,
  and **claim nothing**.

Legacy execution is still paced only by:

- `FOLLOW_IMPORT_EXECUTION_BATCH_SIZE`
- `FOLLOW_IMPORT_EXECUTION_INTERVAL`

## Account-first shadow planning

If the global dispatcher were authoritative, which currently-pending
targets would receive this tick's scheduling share?

```
shadow_plan_budget
    -> owner (account) rotating share
        -> batch rotating share inside that owner
            -> next pending target by position
```

All owners are equal-weight. Splitting one CSV into many batches does
**not** increase that account's top-level share.

`OwnerKey` is an opaque fairness id. The Fedibird adapter derives it
from the local importing account at the batch-loading edge. The planner
does not import `ModerationSubject`, reputation, or handles. A batch
with no derivable owner is skipped (aggregate `skipped_missing_owner_count`)
and does not become its own top-level peer.

`Eligibility` currently always returns true. No Follow Gate / moderation
coupling.

Destination domains travel with plan entries so later destination-share
math can split a cap **across accounts first**. PR B does not enable a
runtime destination cap and does not call DFT / Stoplight.

## `planned_count` vs `claimed_count`

| field | meaning in shadow mode |
|---|---|
| `planned_count` | how many pending targets the allocator selected in this simulation |
| `planned_owner_count` / `planned_batch_count` | distinct owners/batches that received a plan slot |
| `executable_owner_count` / `executable_batch_count` | eligible candidate population after Eligibility / missing-owner filtering — **not** who received a slot |
| `claimed_count` | always **0** — nothing was admitted |

`NULL` means planning/measurement was not attempted or failed.
`0` means planning ran and selected nothing (empty pending set).

Lease busy / shadow disabled / tick error → `planned_count` is NULL.

## Shadow plans are not reservations

A shadow plan describes which **currently pending** work the proposed
allocator would select at observation time. The legacy executor may
claim those rows a moment later. The planner does not `FOR UPDATE`
target rows. A disappearing/queued row is a stale observation.

Because targets stay pending, the same row may appear in a later shadow
plan. That is expected. Owner/batch (and optional per-batch position)
cursors exist so successive ticks do not always start at the same
stable-order prefix.

Cursor advancement means "this owner/batch was served in the
**simulation**", not "this target executed".

## Fairness cursor

Stored in Redis key `follow_import:dispatch:shadow_fairness` (TTL 7
days): last owner, per-owner last batch, per-batch last position.

- Reconstructable scheduler state, not the work ledger.
- Persist cursor entries for the **currently-active** owner/batch set
  and prune inactive ones. There is no `MAX_OWNERS` trim: evicting an
  active owner's last-batch pointer would restart that owner at its
  first batch and starve later batches.
- Redis loss → rebuild from stable DB order (`owner_key`, `batch_id`).
  That may reset fairness quality temporarily; routine eviction of
  active state must not.
- No catch-up credits. Plan budget is unchanged.
- Write failure is non-fatal (`fairness_state_source=persist_failed`).
- Single-flight correctness remains the PostgreSQL advisory lease.

`fairness_state_source`: `redis` / `default` / `reset` / `persist_failed`.

## No remote admission / no load enforcement

Load snapshots are telemetry only. No LocalLoadGuard, no NORMAL/BUSY
labels, no destination cooldown, no AIMD.

## Scheduler registration / cadence

`Scheduler::FollowImportDispatchScheduler` on the `scheduler` queue.
Cadence: `FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL` (default 60s), shared
with `ExecutionPolicy`. Provisional / UNCALIBRATED observation only.

## Why Sidekiq unique lock is not sufficient

`retry: 0, lock: :until_executed` is job dedup only. The PostgreSQL
session advisory lease is the correctness boundary.

## Why the lease uses the thread ActiveRecord connection

`pool.with_connection` so the tick consumes one DB session for the lock
and for counts/planning/telemetry. Unlock in `ensure` on that session.

## Inspecting recent fairness telemetry

```sql
SELECT observed_at, outcome, planned_count, claimed_count,
       planned_owner_count, planned_batch_count,
       executable_owner_count, executable_batch_count,
       unique_destination_count, skipped_missing_owner_count,
       fairness_state_source,
       execution_config ->> 'shadow_plan_budget' AS shadow_plan_budget,
       execution_config ->> 'plan_algorithm' AS plan_algorithm
  FROM follow_import_dispatch_tick_observations
 ORDER BY observed_at DESC
 LIMIT 50;
```

Do not treat those numbers as calibrated production limits.

Target walks use `WHERE batch_id = ? AND state = pending ORDER BY
position, id LIMIT n`. Discovery still uses the pending `batch_id`
partial index. Windowed scans use
`index_follow_import_targets_on_pending_batch_position`
`(batch_id, position, id) WHERE state = pending` so a 20k-target
batch is not sorted on every shadow tick.

The planner rotates owners without calling `remaining?` on every
feed. A target-row SELECT happens only when that owner receives a
scheduling opportunity, plus stale/empty candidates encountered.
The common-case window-query count is proportional to
`shadow_plan_budget`, not `active_owner_count`.
