# Follow Import dispatch shadow scheduler

Status: infrastructure (PR A + PR B + PR D + optional PR E enforcement).
Default: **off**.

This is Stage 1–3 from `docs/follow_import_dispatch_pacing_design.md`.
A global scheduler tick can take a PostgreSQL session advisory lease,
build an **account-first shadow plan**, and write tick telemetry. It
does **not** dispatch, claim, enqueue, pause, or slow Follow Import
execution.

`FollowImport::BatchExecutionWorker` remains the only real claimer.
PR D is historical **shadow observation**. PR E optionally applies the
same `LocalLoadGuard` to the legacy executor; that path is also
**default off** and has no bundled production thresholds.

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

## Shadow LocalLoadGuard (PR D, historical)

PR D added `FollowImport::LocalLoadGuard` as **shadow observation
only**. It consumes the pre-dispatch `LoadSnapshot` already captured
for the tick. It does **not** query Sidekiq again, read telemetry
tables, or look at who is importing.

```bash
FOLLOW_IMPORT_DISPATCH_SHADOW=true
FOLLOW_IMPORT_LOCAL_LOAD_SHADOW=true
FOLLOW_IMPORT_LOCAL_LOAD_PROFILE='{"version":1,...}'
```

`FOLLOW_IMPORT_LOCAL_LOAD_SHADOW` defaults to **false**. When false,
PR B planning is unchanged and the tick records
`local_load_state=disabled`.

The canonical profile variable is `FOLLOW_IMPORT_LOCAL_LOAD_PROFILE`.
`FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE` is a **deprecated** alias
used only when the canonical variable is absent. Do not configure two
independent controller profiles.

There are **no bundled production thresholds**. A blank profile is
`unconfigured`. Malformed JSON or illegal values are `invalid`.
Unexpected controller exceptions are `evaluation_error` (not
`invalid`). Shadow mode leaves the plan at the diagnostic
`shadow_plan_budget` for unconfigured / invalid / unknown /
evaluation_error.

### Profile schema (version 1 — shadow observation)

```json
{
  "version": 1,
  "levels": {
    "busy": {
      "budget_percent": 0,
      "default": { "size": 0, "latency": 0 },
      "push":    { "size": 0, "latency": 0 },
      "pull":    { "size": 0, "latency": 0 },
      "retry_size": 0
    },
    "heavy": { "budget_percent": 0 },
    "overloaded": { "budget_percent": 0 }
  },
  "capacity": {
    "max_tick_claims": 0,
    "per_push_thread": 0,
    "per_pull_thread": 0
  }
}
```

The zeros above are schema placeholders, **not** calibrated defaults.
Operators must supply measured values. Unknown keys are rejected.
Stronger levels must not recommend more budget than weaker ones.
Thresholds for the same signal must be non-decreasing toward
`overloaded`.

`budget_percent` is 0..100. Integer recommendation:

```
capacity_budget = min(base, configured capacity terms that are present)
recommended_budget = (capacity_budget * budget_percent) / 100
```

Floor integer division. No secret minimum of 1. A computed 0 means
`local_load_would_skip=true` for the **shadow plan only**.

### Base vs effective shadow budget

| field | meaning |
|---|---|
| `shadow_plan_budget` | unadjusted PR B diagnostic base |
| `local_load_recommended_budget` | controller output, or NULL if not computed |
| `effective_shadow_plan_budget` | budget actually given to `FairScheduler` |

When the controller is disabled, unconfigured, or invalid, effective =
base. When a usable recommendation exists, effective = recommended
(including 0).

`unknown` / `evaluation_error` share the same control law as live
enforcement: a **v2** profile applies `fallback.budget_percent` to the
tick's `shadow_plan_budget`. A v1 profile has no fallback, so shadow
keeps the base diagnostic budget. The scheduler still claims nothing.

### Missing measurements

If the profile requires a signal the snapshot cannot supply, the
decision is `unknown`, `measurement_complete=false`, and
`recommended_budget` is **NULL** (not 0). A v2 profile then applies
the explicit fallback to the shadow base. A v1 profile keeps the
base diagnostic budget.

### Shadow skip is not a real skip

`planned_count=0` with `local_load_would_skip=true` does **not** stop
`BatchExecutionWorker` by itself. The global tick is never
authoritative. Compare tick `effective_shadow_plan_budget` with the
legacy pass `effective_execution_budget` / `claimed_count` — they may
differ because their base budgets differ.

Fairness cursor advancement follows the **effective** shadow plan. A
0-budget tick does not pretend anyone was served.

## Optional legacy enforcement (PR E)

PR E is the first stage allowed to change the **real** Follow Import
execution rate. It remains legacy per-batch execution. It does **not**
implement global authoritative dispatch, destination pacing, or
moderation coupling.

**No thresholds in the repository are calibrated production
recommendations.**

```bash
# 1. deploy with enforcement OFF (default)
# 2. enable dispatch + local-load shadow and inspect tick telemetry
# 3. configure an explicit enforcement-capable profile including fallback
# 4. only then:
FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT=true
```

`FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT` defaults to **false** and is
**independent** of `FOLLOW_IMPORT_DISPATCH_SHADOW`. Shadow may stay
off while legacy load enforcement is on.

When the flag is false, `BatchExecutionWorker` is unchanged: candidate
limit is `execution_batch_size`, existing gate/reschedule/finalize
behavior is unchanged, and no load-deferred jobs are created.

When the flag is true, enforcement still does **not** silently
activate without a valid **version 2** profile that includes an
explicit fallback. A missing, invalid, v1-only, or otherwise
non-enforcement-capable profile keeps the legacy budget and emits a
rate-limited operational warning. Do not freeze every Follow Import
because the flag was flipped without a profile.

### Profile schema (version 2 — enforcement-capable)

```json
{
  "version": 2,
  "levels": {
    "busy": { "budget_percent": 0, "push": { "latency": 0 } },
    "heavy": { "budget_percent": 0 },
    "overloaded": { "budget_percent": 0 }
  },
  "capacity": {
    "max_tick_claims": 0,
    "per_push_thread": 0,
    "per_pull_thread": 0
  },
  "fallback": { "budget_percent": 0 }
}
```

The zeros above are schema placeholders, **not** calibrated defaults.
`fallback.budget_percent` is required (0..100). There is no bundled
fallback percentage. Live enforcement is not fully configured without
it. v1 remains valid for shadow observation only.

### Worker flow

The worker evaluates its **own** pre-dispatch `LoadSnapshot`. It does
not reuse the latest shadow tick (that decision may already be stale).
`LocalLoadGuard` does not query Sidekiq again.

```
base_execution_budget = ExecutionPolicy.execution_batch_size
recommended_budget    = LocalLoadGuard result (or configured fallback)
effective_execution_budget = min(base, usable recommendation/fallback)
```

`effective_execution_budget` is always `<= execution_batch_size`.
This is **per-pass** protection. Concurrent legacy batches may still
run. Global fairness is PR C.

| Decision | Worker |
|---|---|
| Flag off, or profile not enforcement-capable | Legacy `execution_batch_size`. No load recheck. |
| Positive recommendation | `SELECT ... LIMIT effective_execution_budget`, then existing gate/claim. |
| Budget 0 **because local load** and pending work remains | Claim 0, retain Import, `candidate_count` stays NULL, schedule **exactly one** deferred `BatchExecutionWorker` via `execution_reschedule_in`. |
| Gate / unrecoverable zero progress | Preserve current stop-the-chain semantics. **No** load recheck. |
| No pending targets | Finalize Import as today. No load recheck. |
| Snapshot incomplete / controller error | Apply the explicit fallback (may be 0). Never become unlimited. |

Turning `FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT=false` restores legacy
execution on the **next** worker pass. No DB cleanup. Already-scheduled
deferred jobs may still run; with the flag off they use normal
legacy behavior.

### After enabling enforcement, observe

- `load_deferred` frequency
- actual `claimed_count`
- queue latency / retry pressure
- Import completion delay

Compare global hypothetical `effective_shadow_plan_budget` against
per-batch `effective_execution_budget`. Do not assume they are
numerically identical.

## No remote admission / no global claiming

PR D/E evaluate local load only. No destination cooldown, DFT,
Stoplight, AIMD, `dispatch_owner`, or scheduler claiming.

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
SELECT observed_at, outcome, global_pending_count, planned_count,
       claimed_count, local_load_state, local_load_budget_percent,
       local_load_recommended_budget, effective_shadow_plan_budget,
       local_load_would_skip, local_load_measurement_complete,
       metadata -> 'local_load_reasons' AS local_load_reasons,
       load_snapshot,
       execution_config ->> 'shadow_plan_budget' AS shadow_plan_budget
  FROM follow_import_dispatch_tick_observations
 ORDER BY observed_at DESC
 LIMIT 100;
```

Compare `load_snapshot` queue latency / retry pressure with
`local_load_recommended_budget` to calibrate a later profile. Do not
treat any recorded recommendation as a production limit.

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
