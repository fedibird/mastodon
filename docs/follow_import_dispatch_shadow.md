# Follow Import dispatch scheduler (shadow + GLOBAL)

Status: infrastructure (PR A + PR B + PR D + optional PR E enforcement +
PR C authoritative GLOBAL for **new** imports + PR F fixed remote
admission for GLOBAL ticks + PR G shadow adaptive remote pacing).
Default: **off**.

This is Stage 1–6 (shadow half) from `docs/follow_import_dispatch_pacing_design.md`,
plus I2 operational-cohort scoping. Historical pre-I2 pending rows are
not live scheduler backlog.

One periodic tick, one durable PostgreSQL dispatcher lease, one budget,
one plan:

| GLOBAL | SHADOW | Mode |
|---|---|---|
| false | false | cheap no-op |
| false | true | existing shadow planner over the **operational** cohort; `claimed_count` forced 0 |
| true | * | authoritative scheduler; may claim/enqueue **operational + scheduler-owned** targets |

GLOBAL takes precedence when both flags are true. Do not run a second
shadow allocation in the same tick.

`FollowImport::BatchExecutionWorker` remains the only claimer for
**legacy-owned** batches. New batches created while
`FOLLOW_IMPORT_DISPATCH_GLOBAL=true` are scheduler-owned and must not
enter that worker. PR D is historical shadow observation. PR E
optionally applies `LocalLoadGuard` to the legacy executor (default
off; no bundled production thresholds).

**PR C does not claim production thresholds are calibrated.**

## Activation

```bash
# Diagnostic planner only (no claims)
FOLLOW_IMPORT_DISPATCH_SHADOW=true

# Authoritative claiming for NEW imports (stored dispatch_owner=scheduler)
FOLLOW_IMPORT_DISPATCH_GLOBAL=true
```

Optional diagnostic budget (positive integer; default = current
`FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` / 50):

```bash
FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET=50
```

Exposed as `FollowImport::ExecutionPolicy.dispatch_shadow_enabled?` and
`.shadow_plan_budget`. Do not treat `shadow_plan_budget` as a production
dispatch rate or as the future global budget.

- both false (default): cheap no-op. No lease, no planning, no cursor, no
  tick row, no Follow Import behavior change.
- SHADOW true, GLOBAL false: one process may acquire the global lease,
  inspect **operational** work/load, build a shadow plan, write
  `follow_import_dispatch_tick_observations`, and **claim nothing**.
  Historical batches are omitted from discovery, fairness, and
  `planning_*` counts. `global_pending_count` still reports the
  all-pending universe.
- GLOBAL true: the same tick may claim/enqueue operational
  scheduler-owned pending targets through
  `FollowImport::DispatchExecutor`. Legacy-owned batches and
  historical batches are excluded from the plan.

Legacy execution is still paced only by:

- `FOLLOW_IMPORT_EXECUTION_BATCH_SIZE`
- `FOLLOW_IMPORT_EXECUTION_INTERVAL`

## Account-first shadow planning

If the global dispatcher were authoritative, which currently-pending
**operational** targets would receive this tick's scheduling share?

Historical pending exists because some pre-I2 import rows were recorded
before controlled execution and never transitioned in this ledger era.
Those rows are not a safe replay list and must not consume shadow
fairness slots. Do not infer cohort from `imported_at`, target state,
or the current GLOBAL/SHADOW flag.

```
shadow_plan_budget
    -> owner (account) rotating share (operational cohort only)
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

Tick schema version **10**. Do not rewrite old rows. Schema 9 and
earlier treated `global_pending_count` / `active_batch_count` as the
all-pending universe; schema 10 keeps that meaning and adds scoped
cohort counts. `execution_config.backlog_scope_strategy` is
`dispatch_cohort_v1`.

| field | shadow | global |
|---|---|---|
| `scheduler_mode` | `shadow` | `global` |
| `planned_count` | allocator simulation size | same plan size |
| `claimed_count` | always **0** (writer-enforced) | actual successful `RelationshipWorker` enqueues |
| `global_base_budget` / `effective_global_budget` | NULL | provisional per-tick ceiling and post-load budget |

`NULL` means planning/measurement was not attempted or failed.
`0` means planning ran and selected/claimed nothing.

A partial enqueue failure must keep plan/claim detail
(`planned_count=10`, `claimed_count=3`, `error_class=...`) rather than
collapsing into a nil-count error row.

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
- Single-flight correctness remains `FollowImport::DispatchLease`
  (durable row + fencing generation). This cursor is not a lock.

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
`BatchExecutionWorker` by itself while GLOBAL is off. Compare tick
`effective_shadow_plan_budget` with the legacy pass
`effective_execution_budget` / `claimed_count` — they may differ
because their base budgets differ. When GLOBAL is on, a zero
`effective_global_budget` claims nothing, does not discover pending
work, does not move the fairness cursor, and does not enqueue deferred
legacy workers; the next periodic tick is the recheck.

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
run. Global fairness for **new** imports is PR C
(`FOLLOW_IMPORT_DISPATCH_GLOBAL`).

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

## Fixed remote admission (PR F, GLOBAL only)

Default **off**: `FOLLOW_IMPORT_REMOTE_ADMISSION_ENFORCEMENT=false`.
When the flag is off, the GLOBAL scheduler keeps PR C destination
behavior (finite global / local-load budget only). Shadow ticks never
claim that remote admission was evaluated.

When the flag is on, a valid `FOLLOW_IMPORT_REMOTE_ADMISSION_PROFILE`
is required before fixed policy is enforced. The profile is structural
JSON (version 1) with operator-supplied caps, TTLs, and scan bounds.
Blank / malformed / unknown-version / unknown-key / non-positive values
are unconfigured or invalid. **No bundled production numeric defaults.**
No repository number is a calibrated production recommendation.

Enforced only for scheduler-owned GLOBAL batches:

```
local global budget
    -> account fairness
        -> batch fairness
            -> remote admission
                -> target plan
                    -> DispatchExecutor
```

Remote admission may skip a candidate **for this tick** because of:

- the configured destination-domain per-tick cap (shared across
  accounts and batches; new claims only)
- the configured endpoint-origin per-tick cap, only when a fresh
  `destination_domain → endpoint_origin` mapping exists
- an exact `UnavailableDomain` / DFT host match on the destination or
  mapped origin host
- an active Retry-After honor window
- a configured recent-429 cooldown

Skipped targets stay `pending`. They are not rejected follows,
failures, moderation signals, completed, or deleted. The planner keeps
looking for other healthy targets inside the configured scan budget.

Local destinations do not consume remote destination/origin caps and
are not checked against `UnavailableDomain`. Missing
`destination_domain` uses an internal `__unknown_destination__` bucket
so it is never treated as unlimited.

`DeliveryObserver` writes Redis runtime state
(`follow_import:remote_admission:v1:...`) from an actual HTTP attempt:
privacy-safe `EndpointOrigin` mapping plus Retry-After / recent-429
suppression. Suppression extension is atomic (`max` of honor_until) so
concurrent DeliveryWorkers cannot shorten a longer wait. TTL comes
only from the profile and the final stored honor_until. Redis loss
does not lose work; the destination cap still applies. An empty tail
probe does not consume a scan window, so `max_windows_per_batch = 1`
can still wrap.

**Stoplight is not inspected pre-claim.** Stoplight 3.0.2 in this
repository does not expose a clearly safe read-only admission lookup
that we can use without inventing inbox keys. Resolve/Delivery
Stoplight remain transport-layer fallback.

PR F does **not** add AIMD, learned capacities, 5xx/timeout adaptive
budgets, Node scores, software-type heuristics, active probes, raw
telemetry hot-path reads, or Accept/Reject/moderation inputs. Those
remain PR G/H or later. Retries stay outside the admission budget.

`FOLLOW_IMPORT_DISPATCH_SHADOW` still never claims. Do not treat a
shadow tick as remote-admission enforcement.

Overwrite-generated UNFOLLOW operations remain an unpaced burst.
Retries of `Import::RelationshipWorker` / `ActivityPub::DeliveryWorker`
do not re-enter this scheduler.

## Shadow adaptive remote pacing (PR G)

Default **off**: `FOLLOW_IMPORT_REMOTE_ADAPTIVE_SHADOW=false`.
Adaptive recommendations **never** change actual claim / admission
in this PR. PR F `RemoteAdmission` remains the only remote
enforcement. The same inputs and the same PR F profile must produce
the same claimed target IDs and counts with the flag on or off.

```
actual:  Fixed RemoteAdmission or PR C NullAdmission -> claim / skip
shadow:  AdaptiveRemoteAdvisor -> would this current claim have been
         blocked if adaptive were enforcing? Telemetry only.
```

Shadow routing reads `candidate[:destination_domain]` and an
observation-only PR F `RemoteRuntimeState` snapshot for
`destination_domain → endpoint_origin` mapping. That snapshot is
shared with fixed admission when PR F is on, and is still created
when PR F enforcement is off so mapped-origin telemetry works.
It must not apply destination/origin caps, UnavailableDomain, or
Retry-After / recent-429 suppression. `NullAdmission` remains the
actual decision in that mode.

The adaptive controller is **not** a replacement for fixed admission.
It is an inner shrink whose recommended cap is always
`<=` the corresponding PR F destination / origin per-tick cap.

Activation requires all of:

1. `FOLLOW_IMPORT_REMOTE_ADAPTIVE_SHADOW=true`
2. a valid `FOLLOW_IMPORT_REMOTE_ADAPTIVE_PROFILE` (schema version 1)
3. a valid PR F `FOLLOW_IMPORT_REMOTE_ADMISSION_PROFILE` whose
   destination / origin caps are compatible ceilings
   (`adaptive initial_cap` and `min_cap` must be `<=` the matching
   fixed cap)

Blank = `unconfigured`. Malformed / unknown key / illegal range =
`invalid`. Flag ON + unconfigured/invalid/incompatible: scheduler
and delivery keep working, adaptive stays inactive, PR F behavior
is unchanged, telemetry can tell the cases apart.

There is **no** `FOLLOW_IMPORT_REMOTE_ADAPTIVE_ENFORCEMENT` flag here.
PR H alone may later enforce recommendations.

### Control law (AIMD / slow recovery)

Test fixtures may use synthetic numbers. The repository does **not**
ship production AIMD coefficients, min/initial caps, stale windows,
or multipliers.

| Event | Action |
|---|---|
| Unknown / fresh Redis state | `initial_cap` |
| HTTP 2xx | add success credit; after `successes_per_increase`, `+ additive_step` up to the fixed ceiling |
| HTTP 429 | `rate_limit_multiplier_percent` decrease and credit reset |
| HTTP 5xx / timeout / connection / SSL | `failure_multiplier_percent` decrease and credit reset |
| Ordinary 4xx / 3xx / unknown exception | neutral |
| Stoplight / DFT before the request starts | neutral |
| Accept / Reject / Follow Gate / moderation / reputation | **never an input** |
| `request_duration` / latency | **not** a PR G input |
| Stale, digest-mismatched, corrupt, or lost state | conservative `initial_cap` |

HTTP status wins when both status and exception are present, so a
503 carried by `UnexpectedResponseError` is a 5xx.

PR F Retry-After / recent-429 suppression is unchanged and remains
authoritative for "do not send now". Adaptive may lower the
*resume* cap after that window. It does not create a second cooldown
or copy `honor_until`.

Retries are observation input only. They do not consume the
destination claim budget and do not re-enter the dispatcher.

No active probing. No raw `follow_import_transport_observations`
SELECT from the scheduler hot path. State is written at the actual
delivery attempt into a separate Redis namespace:

```
follow_import:remote_adaptive:v1:destination:<destination_domain>
follow_import:remote_adaptive:v1:origin:<endpoint_origin>
```

One key transition is atomic (Lua). Inbox path/query is never stored.
Missing destination is not persisted as `__unknown_destination__`.
Local destinations are excluded. Shared inbox origins share one
origin controller.

Redis read failure never changes actual admission. Shadow then uses
the conservative initial cap (`runtime_unavailable`). Write failure
never fails delivery, PR F admission, or telemetry.

### Shadow counters

Among actual fixed admits, cap=2 means:

1. first current claim → shadow admit
2. second → shadow admit
3. later current claims → would-block (hypothetical counter is not consumed)

`adaptive_shadow_would_block_current_claim_count` is that extra-stop
count. It is **not** an alternate planned_count.

A GLOBAL local-load zero-budget tick must not instantiate adaptive
Redis/advisor state. Shadow scheduler mode (`GLOBAL=false`) must not
claim that adaptive evaluation occurred (those columns stay NULL).

## Scheduler registration / cadence

`Scheduler::FollowImportDispatchScheduler` on the `scheduler` queue.
Canonical cadence: `FOLLOW_IMPORT_DISPATCH_INTERVAL` (default 60s),
shared with `ExecutionPolicy`. Deprecated alias:
`FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL` when the canonical variable
is absent. Provisional / UNCALIBRATED. Once GLOBAL is on this interval
is real admission pacing, not "shadow observation cadence". No
catch-up budget.

## Why Sidekiq unique lock is not sufficient

`retry: 0, lock: :until_executed` is job dedup only. Redis can lose
that lock. The durable PostgreSQL lease row plus fencing generation
is the correctness boundary for one global admission budget. Target
row locks still prevent double-send of one follow; they do not
enforce that budget.

Transaction pooling (PgBouncer, `PREPARED_STATEMENTS=false`) is a
supported deployment topology. Session-level PostgreSQL features
(`pg_try_advisory_lock`, `pg_advisory_unlock`, assuming
`pg_backend_pid()` is stable across autocommit statements, disconnect
as unlock) must not be used as cross-transaction dispatcher state.

## Why the lease is a durable row, not a checked-out session

A short `pg_try_advisory_xact_lock` transaction serializes
acquire/steal. PgBouncer pins a server backend only for that
explicit transaction. Snapshot, plan, and telemetry then use
ordinary connections and may still be running after `expires_at`.
That is not an authoritative claim. Ownership is
`(owner_token, fencing_generation)` with `expires_at` compared to
PostgreSQL `clock_timestamp()`. The TTL is
`ExecutionPolicy.dispatch_interval` (crash-recovery bound, not a new
pacing number). GLOBAL `pending -> queued` is fenced: a short
transaction locks the singleton lease row, verifies the current
generation, and applies `mark_queued` in that same transaction.
Enqueue happens after that claim commits. Stale generations cannot
perform authoritative claims.

Seeing advisory key `(classid=17993, objid=1, objsubid=2)` only
during the short acquire transaction is expected. Seeing it stranded
on an idle backend between ticks is not.

`objsubid = 2` is the PostgreSQL two-integer locktag form for both
session-level and transaction-level advisory locks on `(17993, 1)`.
`objsubid = 1` is the single-bigint representation, not “session vs
xact”. The verification query below is the relevant one.

GLOBAL must remain off until production shadow verification confirms
the new mechanism: ticks succeed at approximately the configured
cadence, `lease_busy` is genuine overlap rather than a leaked
session lock, and this query returns **zero rows** between ticks:

```sql
SELECT
  l.pid,
  l.mode,
  l.granted,
  l.classid,
  l.objid,
  l.objsubid,
  a.state,
  a.state_change,
  left(a.query, 200) AS query
FROM pg_locks l
LEFT JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.locktype = 'advisory'
  AND l.classid = 17993
  AND l.objid = 1
  AND l.objsubid = 2;
```

### Cutover: clear #135 stranded session locks before enabling #137

The new xact lock reuses `(classid=17993, objid=1, objsubid=2)`. A
#135-era **session** advisory lock granted on that same key conflicts
with `pg_try_advisory_xact_lock`, so a leftover holder makes every
#137 tick `lease_busy`.

Pre-deploy / cutover (operator action; application code must not
call `pg_terminate_backend`):

1. Keep `FOLLOW_IMPORT_DISPATCH_GLOBAL` off. Temporarily stop
   SHADOW / scheduler acquisition (disable the scheduler or set
   `FOLLOW_IMPORT_DISPATCH_SHADOW=false` and restart Sidekiq
   scheduler processes).
2. Identify granted advisory holders with the query above.
3. Recycle or terminate those legacy PostgreSQL **server** backends
   (the PgBouncer client disconnect is not enough).
4. Re-run the query and confirm **zero** granted rows.
5. Deploy / restart #137 processes, then re-enable SHADOW only.
6. Confirm `execution_config.lease_strategy = durable_row_v1` and
   that `lease_busy` is only genuine overlap.

## Inspecting recent fairness telemetry

```sql
SELECT observed_at, outcome, global_pending_count, historical_pending_count,
       operational_pending_count, planning_pending_count, planned_count,
       claimed_count, local_load_state, local_load_budget_percent,
       local_load_recommended_budget, effective_shadow_plan_budget,
       local_load_would_skip, local_load_measurement_complete,
       metadata -> 'local_load_reasons' AS local_load_reasons,
       load_snapshot,
       execution_config ->> 'shadow_plan_budget' AS shadow_plan_budget,
       execution_config ->> 'backlog_scope_strategy' AS backlog_scope_strategy,
       execution_config ->> 'schema_version' AS schema_version
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
