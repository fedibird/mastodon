# Follow Import dispatch shadow scheduler (PR A)

Status: infrastructure / observation only.
Default: **off**.

This is the Stage 1 skeleton from
`docs/follow_import_dispatch_pacing_design.md`. It lets one global
scheduler tick run, hold a PostgreSQL session advisory lease, inspect
cheap backlog/load facts, and write tick telemetry. It does **not**
dispatch, claim, enqueue, pause, or slow Follow Import execution.

`FollowImport::BatchExecutionWorker` remains the only real claimer.

## Activation

```bash
FOLLOW_IMPORT_DISPATCH_SHADOW=true
```

Exposed as `FollowImport::ExecutionPolicy.dispatch_shadow_enabled?`.
The raw ENV is not read from workers or observers.

- `false` (default): `Scheduler::FollowImportDispatchScheduler` is a
  cheap no-op. No lease, no planning, no tick row, no Follow Import
  behavior change.
- `true`: one process may acquire the global lease, inspect current
  work/load, write `follow_import_dispatch_tick_observations`, and
  **claim nothing**.

Do not enable this to change production pacing. Legacy execution is
still paced only by:

- `FOLLOW_IMPORT_EXECUTION_BATCH_SIZE`
- `FOLLOW_IMPORT_EXECUTION_INTERVAL`

Those knobs are unchanged.

## Scheduler registration / cadence

Registered in `config/sidekiq.yml` as
`Scheduler::FollowImportDispatchScheduler` on the `scheduler` queue,
`every: '1m'`.

That interval is **provisional / UNCALIBRATED** shadow observation. It
is not a calibrated dispatch tick and must not be treated as
`FOLLOW_IMPORT_EXECUTION_INTERVAL`. The eventual real dispatch cadence
is not chosen here.

## Why Sidekiq unique lock is not sufficient

The worker uses `sidekiq_options retry: 0, lock: :until_executed`
(same convention as `Scheduler::AccountsStatusesCleanupScheduler`).

`lock: :until_executed` only deduplicates Sidekiq jobs. Redis can lose
that lock (restart, eviction). Two jobs may then start. The
correctness boundary for "only one global tick is in the critical
section" is `FollowImport::DispatchLease`.

## Why the PostgreSQL session advisory lease holds a connection

`pg_try_advisory_lock` / `pg_advisory_unlock` are **session** locks.
They survive `COMMIT` and `ROLLBACK`. They are released only by unlock
on the same session or by disconnect.

`FollowImport::DispatchLease` therefore checks out **one** ActiveRecord
connection, acquires the lock on that connection, keeps it checked out
for the tick, and unlocks on the **same** connection in `ensure`. A
still-locked connection is never intentionally returned to the pool.
If unlock cannot be confirmed, the connection is disconnected and
removed.

The lock identity is the documented pair `0x4649` (`FI`) + `1`, not
Ruby `String#hash` (process-randomized).

The tick is **not** wrapped in `pg_try_advisory_xact_lock` or one long
transaction.

## Why scheduler retry is disabled

`retry: 0` so a raised tick does not replay. There is no stored budget
in PR A; later claiming PRs must also start each tick from a fresh
snapshot rather than catching up missed budgets.

## Why `claimed_count` is always zero

PR A never calls `TargetTransitionService#mark_queued` and never
enqueues `Import::RelationshipWorker` or `ActivityPub::DeliveryWorker`.
The tick writer forces `claimed_count = 0` so shadow observations
cannot be mistaken for real admission.

## Tick telemetry

Table: `follow_import_dispatch_tick_observations`.

Dedicated from per-batch `follow_import_dispatch_observations` so a
legacy worker pass that claimed N is not mixed with a global tick that
claimed 0.

Outcomes: `shadow_disabled` (in-memory only; no row), `lease_busy`,
`shadow_observed`, `shadow_error`.

`0` on a count is an observed empty set. `NULL` is an unavailable
measurement. Insert failure is a rate-limited warning and does not
raise into Follow Import or the scheduler job.
