# Follow Import dispatch and pacing

Status: **design / pre-implementation**. This document is not an
implementation contract that has already shipped. It does not change
runtime behaviour.

Numeric thresholds in this document are **provisional and uncalibrated**.
[PR #59](https://github.com/fedibird/mastodon/pull/59) added
observation-only transport and dispatch telemetry. Those measurements must
be collected in production before any number here is treated as an
operational default. This revision does **not** invent production
thresholds.

This document is written so it can be used for:

1. a Fedibird implementation of the dispatcher
2. a later technical proposal toward Mastodon, if the architecture proves out

The core is therefore strictly operational: transport pacing, backpressure,
fairness, scheduling, remote-server protection, retry/recovery, and
observability. It is **not** a moderation, abuse, or reputation design.

---

## Decisions we can make now vs numbers that must wait

### Architectural decisions (can be made now)

These are control-flow and responsibility choices. They do not depend on a
measured p95.

- Dispatch is a **global, tick-driven scheduler**, not N independent
  per-batch Sidekiq chains racing each other.
- **Fairness is account-first**, then batch, then target. Splitting one
  CSV into many batches must not multiply throughput.
- The portable core depends on a neutral **owner / fairness key**, not on
  `ModerationSubject`.
- Concurrent scheduler ticks are **single-flight**. The DB **session**
  advisory lease is the correctness boundary (checked-out connection,
  explicit unlock). Target row locks are necessary but not sufficient
  for a global budget. Claim budget is not a strict HTTP-attempt cap.
- The **database target set** remains the source of truth. Sidekiq is a
  transport, not business state. Redis is not a second budget ledger.
- Claim-then-enqueue stays **idempotent and row-locked**.
- **Eligibility** (may this import run at all?) is an external boolean.
  The pacing system must not know *why* an import is paused.
- **Local load** can skip or shrink a tick. It must not drop claimed work
  or rewrite target results.
- **Remote protection** is admission control at claim time, using only
  signals that are actually available before resolve/inbox URL is known.
- Prefer **skip this target this tick and pick another** over stalling a
  whole import or the whole dispatcher.
- Reuse existing **Stoplight**, **DeliveryFailureTracker**,
  **UnavailableDomain**, HTTP **Retry-After**, and Sidekiq retries. Do not
  invent a second circuit breaker that fights them. Do not assume every
  Stoplight key is visible pre-claim.
- Ordinary (non-import) Follow API behaviour is unchanged in the first
  implementation.
- **Node capacity scores** are out of scope.
- Once the global dispatcher is authoritative, **unpaced
  `import_relationships!` fallback is forbidden**. Durable batch/target
  recording is required.
- Control-data failure **degrades to a conservative baseline**, not to
  "unlimited" and not to a deadlock of all imports.

### Numeric parameters (must wait for PR #59 telemetry)

Treat every figure below as a placeholder label, not a ship default.

- Tick interval
- Global claim budget and how it scales with `push` / `pull` concurrency
- Per-account floor and cap per tick
- Per-batch floor and cap *within* one account's share
- Per-destination and per-endpoint claim caps (per tick and per sliding
  window)
- Conservative unknown-destination cap (used when remote state is missing)
- Candidate-window size and `MAX_SCAN_TARGETS` / `MAX_SCAN_WINDOWS`
- Adaptive AIMD coefficients, windows, minima/maxima (PR G/H only)
- Local-load skip / shrink envelopes (queue size, latency, retry set)
- How long to honour `Retry-After` in the dispatcher
- Mapping-cache TTL / staleness for `destination_domain → endpoint_origin`
- Telemetry aggregation windows used as limiter input
- How many consecutive empty ticks before an operator alert

Until those are calibrated, the current env knobs remain the only
production pacing (`FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` default 50,
`FOLLOW_IMPORT_EXECUTION_INTERVAL` default 30s). They are themselves
uncalibrated.

---

## 1. Scope

In scope:

- gradual Follow Import dispatch
- local instance load protection
- remote instance protection
- fair scheduling between simultaneous **accounts**, then their batches
- domain- and endpoint-aware pacing
- failure / backoff integration
- durable DB-backed execution
- scheduler single-flight / restart behaviour
- observability, staged rollout, and implementation-PR decomposition

Out of scope (do not implement, and do not feed into the dispatcher):

- abuse detection
- user reputation
- nuisance scoring
- interpretation of block / mute / report
- moderation action
- GDPR / privacy policy for moderation datasets
- Follow Gate decision criteria
- Node capacity scoring
- changing ordinary Follow API behaviour in this first implementation

A separate policy layer may eventually say "this import is paused / not
executable". The pacing system must not know why.

---

## 2. Conceptual boundary

```
                    ┌─────────────────────────────────────┐
                    │  Eligibility / policy (external)    │
                    │  executable?(batch) → true | false  │
                    │  The dispatcher does not know WHY.  │
                    └──────────────────┬──────────────────┘
                                       │
                    ┌──────────────────▼──────────────────┐
                    │  Dispatch / pacing (this document)  │
                    │  owner_key → batch → target         │
                    │  single-flight global budget        │
                    │  local load + remote admission      │
                    └──────────────────┬──────────────────┘
                                       │ claim pending → queued
                    ┌──────────────────▼──────────────────┐
                    │  Transport (existing workers)       │
                    │  Import::RelationshipWorker         │
                    │  FollowService                      │
                    │  ActivityPub::DeliveryWorker        │
                    └──────────────────┬──────────────────┘
                                       │
                    ┌──────────────────▼──────────────────┐
                    │  Existing failure machinery         │
                    │  Sidekiq retry                      │
                    │  Stoplight (resolve vs delivery)    │
                    │  DeliveryFailureTracker             │
                    │  UnavailableDomain                  │
                    └─────────────────────────────────────┘
```

**Eligibility** answers: is this batch allowed to receive claims right now?

Examples of who might set `executable? = false` later (not designed here):
an operator pause, a maintenance flag, or an unrelated policy product. The
dispatcher receives a boolean. It must not import risk scores, friction
names, or reason codes.

**Pacing** answers: given the executable set, which pending targets are
claimed this tick, subject to a single global budget, account-first
fairness, local load, and remote admission.

**Transport** answers: resolve the acct and deliver one Follow. That path
already exists. The first implementation must not special-case Follow
creation for imports beyond the tracking / telemetry already present.

Fedibird today evaluates `FollowImport::ExecutionGate` inside
`BatchExecutionWorker` and can, if an experimental flag is on, refuse a
whole pass. That gate is a **Fedibird eligibility adapter**. It is not
part of the portable pacing core. For a future upstream proposal, replace
it with a narrow `executable?(batch)` hook (default `true`). Adapter
failure may remain fail-open for *business availability* (do not freeze
the user's import because the adapter crashed). That is separate from
traffic-safety fallback (§4.9).

### 2.1 Owner / fairness key (portable)

Hierarchy:

```
account  (owner / fairness key)
  └── batch
        └── target
```

Top-level fair share is per **importing account**. Within one account,
multiple batches are then scheduled fairly.

```
Global budget
    |
    +-- Account A share
    |      +-- batch A1
    |      +-- batch A2
    |
    +-- Account B share
           +-- batch B1
```

A user with 10 batches must not receive 10× the throughput of a user with
1 batch.

The portable pacing core depends only on an opaque **`owner_key`**
(typically the importing account id). It must not import
`ModerationSubject`, risk tables, or ledger types.

Fedibird can *derive* `owner_key` today via
`FollowImportBatch#for_account` / `ModerationSubject`. That derivation is
an adapter at the batch-loading edge:

```
owner_key_for(batch) → batch.for_account&.id   # Fedibird adapter
```

Upstream, the same interface is `batch.account_id` (or equivalent). The
allocator, cursors, destination sharing, and telemetry dimensions use
`owner_key`, never `subject_id`.

---

## 3. Current behaviour (problem statement)

Follow Import already has a durable execution model:

- `FollowImportBatch` / `FollowImportTarget` are the work set.
- Target states: `pending` → `queued` → `awaiting_delivery` →
  `awaiting_response` → terminal (`accepted`, `rejected`,
  `completed_no_response`, `delivery_failed`).
- `FollowImport::BatchExecutionWorker` claims up to
  `execution_batch_size` pending rows **in CSV `position` order**, marks
  them `queued`, and enqueues `Import::RelationshipWorker`.
- The worker **self-reschedules** after `execution_reschedule_in` only
  when the pass claimed at least one target.
- The CSV is not the unit of work; it is only used to recover address /
  options for a claimed row.
- Ordinary Follow delivery still goes through `FollowService` and
  `ActivityPub::DeliveryWorker` (`push` queue, retry 16).
- Resolve still goes through `Import::RelationshipWorker` (`pull` queue,
  retry 8) and `Stoplight("source:#{domain}")`.
- Delivery uses `Stoplight(@inbox_url)` — a **different key**.

What this does **not** do:

- There is **no global budget**. Two concurrent 10k imports each fire 50
  follows every 30s. Ten concurrent imports fire 500. Dispatch rate is
  `active_batches × batch_size / interval`, i.e. Sidekiq-chain fan-out.
  Two overlapping ticks of a future global scheduler would have the same
  bug unless single-flight is explicit (§5.2).
- There is **no local-load short-circuit**. PR #59 records a pre-dispatch
  `LoadSnapshot` but never skips or shrinks a pass because the instance is
  busy.
- There is **no domain or endpoint limiter** at claim time.
  Delivery-layer backoff happens **after** claim+enqueue.
- Fairness is accidental and **batch-scoped**. One account that opens
  many batches gets many independent 50/30s chains.
- If batch recording fails, `ImportService` falls back to
  `import_relationships!` (bulk enqueue) and
  `ProcessImportWorker` then **destroys the Import** because no batch
  exists. That is an unpaced safety bypass once global pacing is meant
  to be authoritative (§9.5).

`Scheduler::AccountsStatusesCleanupScheduler` already shows useful
shapes: `lock: :until_executed`, skip-when-loaded, budget from `push`
concurrency, per-account cap so one account cannot consume the tick.
Follow Import should learn from those *patterns*, not copy its constants.

### 3.1 Historical domain-oriented CSV / list ordering

Older Follow Import paths (and operator folklore) sometimes **grouped or
preceded work by destination domain** — sort the CSV / walk one remote
at a time.

That was **not** a long-term delivery policy and was **not** intended as
fair scheduling. It was a pragmatic pre-flow-control workaround:

- Existing Stoplight / circuit breakers only trip after several failures
  *on the same key*.
- If work for a dead remote is interleaved with healthy remotes, the
  circuit stays closed longer and every bad row still pays resolve /
  connect cost.
- Grouping the same destination together made failures for that
  destination reach the existing breaker *quickly*, so subsequent rows
  for that host could be skipped by transport.

With a global dispatcher plus destination admission control, that
workaround is unnecessary:

- the dispatcher can skip a known-bad `destination_domain` without
  having to cluster those rows in the CSV
- clustering is actively harmful for *healthy* popular destinations
  (it produces a burst against one host)
- CSV `position` is only a tie-break, not a domain walk

The historical hack must not define future scheduling semantics. It can
be retired once the dispatcher + admission control are proven (PR I).

---

## 4. Design principles

1. **Gradual by default.** An import of N follows is N claim decisions
   spread over many ticks, not N Sidekiq jobs dumped at parse time.
2. **Account-first fairness.** Simultaneous *accounts* share one instance
   budget. Batches are a sub-queue of an account. Splitting CSVs must not
   pay.
3. **Protect the local instance first.** If `default` / `push` / `pull`
   (or the retry set) are already beyond a load envelope, the tick claims
   nothing. Existing in-flight jobs finish; we do not enqueue more.
4. **Protect remotes second.** Do not claim a target whose *available*
   pre-claim signals say wait. Fill the tick with other destinations,
   other batches of the same account, or other accounts.
5. **Claim is a promise to enqueue.** If enqueue fails, release the claim
   (`queued` → `pending`) as today. Never leave a row `queued` with no job.
6. **Delivery success ≠ follow accepted.** Pacing ends at claim+enqueue.
   Accept / Reject / `completed_no_response` stay result states, not
   rate-limit inputs.
7. **Reject is not a pacing signal.** A remote Reject is a follow result.
8. **Absence of evidence is not evidence of a healthy remote.** Unknown
   destinations get a conservative first-contact cap, not unlimited.
9. **Degrade safely, do not fail open on traffic.** Control-data failure
   must not deadlock all imports, and must not mean "unlimited":
   - Sidekiq load snapshot unavailable → last-good snapshot, else a
     **conservative baseline global budget**
   - adaptive remote state unavailable → **conservative unknown-domain
     cap** (still admit *some* work)
   - Redis pacing cursor / lock lost → conservative initial fairness
     (walk from a stable DB order), **not** a learned high rate
   - eligibility adapter failure → existing fail-open for that batch
     (business availability only)
10. **No second source of truth for work.** Progress and idempotency stay
    on `follow_import_targets`. Scheduler cursors are reconstructable
    from the DB. Redis is not the budget ledger.
11. **One owner per batch.** A batch is claimed either by the legacy
    chain or by the global scheduler, never both.
12. **New claims ≠ all HTTP attempts.** v1 paces admission of new
    Follow Import work. Retries do not re-enter the dispatcher.

---

## 5. Proposed architecture

### 5.1 Components

| Component | Responsibility | New? |
|---|---|---|
| `FollowImport::DispatchScheduler` | Periodic tick; single-flight; load snapshot; budget; plan; claim. Sidekiq wrapper: `Scheduler::FollowImportDispatchScheduler` | **Yes** |
| `FollowImport::DispatchLease` | Process-lifetime serialization of the claim loop (see §5.2) | **Yes** |
| `FollowImport::DispatchPlan` | Pure function: snapshot + executable work + limiter state → ordered claim list | **Yes** |
| `FollowImport::OwnerKey` | Adapter: batch → opaque fairness key | **Yes** (thin) |
| `FollowImport::RemoteAdmission` | Pre-claim signals actually available (see §7) | **Yes** |
| `FollowImport::LocalLoadGuard` | Shared `under_load?` / baseline budget from a snapshot | **Yes** |
| `FollowImport::Eligibility` | `executable?(batch)` (default true) | Thin wrapper |
| `FollowImport::TargetTransitionService` | Claim / release / later result transitions | Existing |
| `Import::RelationshipWorker` | Resolve + `FollowService` | Existing |
| `ActivityPub::DeliveryWorker` | HTTP delivery + inbox Stoplight + DFT | Existing |
| PR #59 telemetry | Observations for later calibration and optional aggregates | Existing |

`BatchExecutionWorker` remains during rollout as a **legacy per-batch
chain** for batches it already owns. The end state is: `ImportService`
records the batch and does **not** `perform_async` the per-batch worker.
The scheduler discovers scheduler-owned pending work from the partial
index on `state = pending`.

### 5.2 Single-flight / global budget serialization

Row-locking a target prevents **that target** from being dispatched
twice. It does **not** enforce a global budget. Two overlapping ticks
that each compute `budget = 50` can claim 100 different rows.

**Preferred architecture (simplest, existing Mastodon convention + one
DB lock):**

1. **Sidekiq unique job** on the scheduler:
   `sidekiq_options retry: 0, lock: :until_executed`
   (same pattern as `Scheduler::AccountsStatusesCleanupScheduler`).
   This prevents a pile-up of overlapping *jobs* while one tick runs.
2. **PostgreSQL session advisory lock** around plan+claim+enqueue
   (`pg_try_advisory_lock` / `pg_advisory_lock` with a dedicated
   Follow Import dispatch key). This is the **correctness boundary**
   for the global budget. Sidekiq `lock: :until_executed` only
   deduplicates jobs; it is not enough if Redis loses the unique lock.
3. **No Redis remaining-budget counter.** There is no "owed" work
   accumulated across ticks. A tick either holds the lease and admits
   up to *this* tick's budget, or it does nothing.

**Session-lock semantics (implementation requirement):**

`pg_advisory_lock` / `pg_try_advisory_lock` are **session-level**. They
survive `COMMIT` and `ROLLBACK`. They are released only by:

- explicit `pg_advisory_unlock` on the **same PostgreSQL session**, or
- session disconnect / crash.

They are **not** released on commit/rollback. Therefore the
implementation must:

- check out **one** ActiveRecord connection for the lease lifetime
- acquire the advisory lock on **that exact connection**
- keep that connection checked out through plan / claim / enqueue
- explicitly `pg_advisory_unlock` on that same connection in `ensure`
- **not** return a still-locked connection to the pool
- **not** wrap the whole dispatch/enqueue tick in a long DB transaction
  that uses `pg_try_advisory_xact_lock` (enqueue and Sidekiq must not
  sit inside an open transaction spanning the tick)

Per-target claim transactions may still `COMMIT` independently on that
same checked-out connection (or on short-lived others for row work,
provided the lease connection stays checked out and locked). The lease
connection is held for serialization, not to make the tick one ACID
unit.

#### Process crash while holding the lease

The Sidekiq unique lock expires with `until_executed` (process gone).
The session advisory lock is released only because the **backend
disconnects**. The next tick starts clean: new load snapshot, new
budget. No catch-up.

Target `SELECT … FOR UPDATE` (or the existing row-locked transition)
remains **necessary** so a legacy worker and a scheduler, or a lock
failure, cannot double-send the same follow. It is not sufficient for
pacing.

#### Overlapping Sidekiq ticks

If UniqueJobs / Redis is healthy, the second enqueue is deduplicated or
waits until `until_executed` releases. If a second process nevertheless
starts, `pg_try_advisory_lock` fails → that process records a skipped
tick (`lease_busy`) and exits without claiming. Budget is not added.

#### Scheduler retry

`retry: 0` on the scheduler. A raised tick does not replay a stored
budget. Sidekiq Cron / the next interval starts a new tick. Partial
claims from the failed tick stay claimed+enqueued or released (existing
enqueue-failure path). Pending remainder waits for the next *fresh*
budget.

#### Redis restart

Unique job locks disappear. Two ticks might be enqueued. The advisory
lock still serializes claiming. Fairness cursors stored only in Redis
are lost → rebuild from a stable DB order (`owner_key`, `batch_id`) at
conservative initial deficits (zero). **Not** "we missed 10 ticks, claim
10× budget".

#### DB restart

Advisory locks are gone. In-flight tick dies with the connection.
Uncommitted claims roll back. Committed claims stay. Next tick takes a
new lease and a new (non-multiplied) budget.

#### Why a restart cannot cause a catch-up burst

There is no backlog of unused budgets. Idleness only leaves `pending`
rows. Admission is always `min(computed_budget_for_this_snapshot,
available_pending_after_limiters)`. After an hour down, the first tick
looks like any other tick under current load.

### 5.3 Tick algorithm (normative)

Each scheduler tick, in order:

1. Try the advisory lease. If not acquired → observe `lease_busy`, exit.
2. **Snapshot local load** (`FollowImport::LoadSnapshot`) **before** any
   claim. If the snapshot fails, use last-good or conservative baseline
   budget (§4.9) — never "unlimited".
3. `guard = LocalLoadGuard.from(snapshot)`. If `under_load?` → claim
   zero, observe, exit.
4. `budget = guard.global_budget` (uncalibrated formula; see §6).
5. Load executable, **scheduler-owned** batches with `pending` targets.
   Group by `owner_key`.
6. Refresh `RemoteAdmission` for this tick (§7). Cheap reads and
   caches/aggregates only. No raw telemetry table scan.
7. `plan = DispatchPlan.build(budget, owners → batches, admission,
   cursors)` — account-first, then batch, then diverse targets.
8. For each planned target: claim via
   `TargetTransitionService#mark_queued`; enqueue `RelationshipWorker`
   with today's options. On enqueue failure, release the claim and stop
   the tick. Increment `claimed_count` only after a successful enqueue.
9. Persist fairness cursors (last `owner_key` / per-owner batch cursor /
   deficits). Reconstructable from DB if missing.
10. Write one **tick-level** dispatch observation. Do not skip telemetry
    because the tick claimed nothing.
11. In `ensure`, `pg_advisory_unlock` on the **same checked-out
    connection**, then return that connection to the pool only after
    unlock. A raised tick must still unlock.

Do not enqueue `BatchExecutionWorker` from this path.

### 5.4 Why a global scheduler rather than smarter per-batch workers

A per-batch worker can sleep longer, but it cannot see other accounts'
chains and cannot enforce one budget. Fairness and a global ceiling
require a single allocator. Cleanup-scheduler is the in-tree precedent:
one worker, one budget, many work items, skip-when-loaded.

Sidekiq remains the executor of resolve/delivery. The scheduler only
**admits** claims.

### 5.5 Selection inside a batch (no head-of-line window stall)

Today: `ORDER BY position LIMIT batch_size`.

A **bounded candidate window** is required so a 20k batch is never
fully scanned in one tick. That window must not head-of-line block:
if the first window is entirely a destination in backoff, healthy
targets later in the same batch must still be discoverable.

Bounded paging / scan budget (numbers **uncalibrated**):

1. Inspect one bounded window (`ORDER BY position` after a cursor,
   `LIMIT WINDOW_SIZE`).
2. Skip admission-blocked targets; pick a diverse eligible subset
   (prefer destinations with fewer claims this tick after
   account-level destination sharing, §8.3). `position` is a
   tie-break only.
3. If the **account** still has unused share and this window yielded
   nothing or too little, seek to the next window (advance the
   position cursor past the inspected rows).
4. Stop after `MAX_SCAN_TARGETS` rows inspected **or**
   `MAX_SCAN_WINDOWS` windows for this account/batch in this tick,
   whichever binds first.

Do **not** unbounded-scan a 20k import. Unused share after the scan
budget is exhausted returns to the parent allocator (other batches of
the same account, then other accounts). Record `windows_scanned` /
`scan_budget_exhausted` on the tick observation.

This replaces the historical domain-clustering workaround (§3.1) for
dead hosts (admission skip + paging) and avoids blasting a healthy
popular host.

Unresolved rows still have `destination_domain` (PR #59). They
participate in destination caps. They do not yet have `endpoint_origin`.

---

## 6. Local instance load protection

Model: **admit fewer claims when the instance is already busy**. Do not
cancel in-flight jobs. Do not mark targets failed because we chose not
to claim them.

### 6.1 Signals (already snapshotted by PR #59)

- Queue **size** and **latency** for `default`, `push`, `pull`
- Sidekiq **retry set** size
- Summed **concurrency** of processes listening to `push` / `pull`

Resolve jobs land on `pull`. Follow deliveries land on `push`. Local
follows never hit `DeliveryWorker` (known telemetry gap); they still
consume `pull` and `FollowService`.

### 6.2 Architecture (now)

Two layers, both from the pre-dispatch snapshot (or last-good /
conservative baseline if the snapshot failed):

1. **Hard skip** — `under_load?` → budget 0.
2. **Soft shrink** — budget scales down as the snapshot approaches the
   skip envelope.

Reuse the *shape* of `AccountsStatusesCleanupScheduler#under_load?`.
**Do not reuse its numeric constants.**

`LocalLoadGuard` is a **shared** object. After it is enforced (PR E),
both the global scheduler and any remaining legacy `BatchExecutionWorker`
must call it **before claiming**. A guard that only the shadow scheduler
evaluates does **not** protect the instance.

### 6.2.1 Legacy worker: load-deferred recheck vs true stop

`BatchExecutionWorker` today reschedules only after **positive forward
progress** (`claimed_count > 0`). If Stage-3 enforcement simply yields
zero claims, the legacy chain can **stop forever** while pending rows
remain.

Distinguish zero-claim reasons:

| Why this pass claimed nothing | Legacy chain must |
|---|---|
| No pending targets, or remaining pending rows are not executable / not recoverable (policy, missing CSV address, `executable? = false`) | **Stop** the automatic chain (today's behaviour). Recheck is explicit/manual/policy. |
| `LocalLoadGuard` refused admission (`under_load?` or budget 0) **and** executable pending targets remain | **Enqueue a deferred load recheck** (`perform_in` the usual uncalibrated interval, or a dedicated load-recheck interval). Claim **zero** targets. Do **not** finalize/destroy the Import. |

This recheck is **temporary compatibility** until `dispatch_owner =
scheduler`. It must not be a tight retry loop. The interval stays
uncalibrated (same class of knob as `FOLLOW_IMPORT_EXECUTION_INTERVAL`).

The global scheduler does not have this problem: the next cron tick is
an independent recheck.

Implementation (PR E): enforcement is a separate default-off flag
`FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT`, not coupled to
`FOLLOW_IMPORT_DISPATCH_SHADOW`. Live enforcement requires an
operator-supplied profile schema v2 with an explicit
`fallback.budget_percent`. The worker evaluates its own pre-dispatch
`LoadSnapshot`; it does not reuse the latest shadow tick. Load
deferral is tracked explicitly (`load_deferred`) and must not be
inferred from `claimed_count == 0`.

### 6.3 Provisional load envelope (uncalibrated)

Labels only — replace from telemetry. Cleanup numbers are shown only as
the *existing* in-tree reference, not as Follow Import defaults.

| Signal | Cleanup scheduler today | Follow Import |
|---|---|---|
| `default` size / latency | 2 / 5s | *uncalibrated* |
| `push` size / latency | 5 / 10s | *uncalibrated* |
| `pull` size / latency | 500 / 300s | *uncalibrated* |
| retry set | 50_000 | *uncalibrated* |

`compute_global_budget` is a placeholder shape:

```
budget = min(
  MAX_TICK_CLAIMS,
  PER_PUSH_THREAD * push_concurrency,
  PER_PULL_THREAD * pull_concurrency
)
# shrink toward 0 as snapshot approaches under_load envelopes
```

None of those identifiers are production defaults.

If the snapshot is unavailable and no last-good exists, use a **small
fixed baseline budget** (uncalibrated constant), not `MAX_TICK_CLAIMS`
and not "claim everything pending".

### 6.4 What local load must never do

- Change Follow / Block / Mute API behaviour
- Interpret Accept/Reject
- Pause a batch because of user reputation
- Delete pending targets

---

## 7. Remote instance protection (what is actually available pre-claim)

Before account resolution the dispatcher normally has
`destination_domain` only. It does **not** have the inbox URL.
`endpoint_origin` (PR #59) is also **not** the DeliveryWorker Stoplight
key.

Current keys in this codebase:

| Mechanism | Key | When it exists |
|---|---|---|
| Resolve Stoplight | `source:#{domain}` | RelationshipWorker, after we know the acct domain |
| Delivery Stoplight | exact `@inbox_url` | DeliveryWorker, after Follow is built |
| `UnavailableDomain` / DFT | normalized **host** | after failures against that host |
| PR #59 `endpoint_origin` | scheme + host + non-default port | after an HTTP attempt is observed |
| `destination_domain` | normalized acct domain | at record time, including unresolved rows |

Do **not** require consulting Delivery Stoplight at claim time. Do **not**
scan raw `follow_import_transport_observations` every tick. Do **not**
invent a Node capacity score.

### 7.1 Pre-claim admission layers

| Layer | Available pre-claim? | Dispatcher use |
|---|---|---|
| **Destination-domain first-contact cap** | Always (`destination_domain` on the row) | Always-on conservative cap per tick / window. Unknown remotes stay capped. |
| **Resolve Stoplight `source:#{domain}`** | Only if Stoplight exposes a **safe status lookup** that does not run the block and does not require opening a circuit as a side effect | If such a lookup exists, may skip that destination this tick. If it does not, this layer is **transport-only** (RelationshipWorker fallback already returns `nil`). |
| **UnavailableDomain / DFT** | Host-based. Usable when the destination host is the DFT host (common for simple `acct@host`). Wrong when shared-inbox / CDN host ≠ acct domain | Skip when the mapped host is known unavailable. Do not guess a host. |
| **Retry-After / recent 429** | After at least one observed attempt, via a **runtime cache or aggregate** keyed by `endpoint_origin` (not raw-table scan) | Do not claim that origin until honour-until (capped; uncalibrated). |
| **Delivery Stoplight exact inbox** | **Not** available pre-claim unless a reliable inbox mapping exists | Remains **transport-layer** protection. Do not pretend claim-time can see it. |

Honor `Retry-After` when the cache has it; cap the honour window
(uncalibrated) so a pathological header cannot freeze an origin inside
the dispatcher for unbounded time. DeliveryWorker retries still apply
their own backoff.

### 7.2 Optional `destination_domain → endpoint_origin` map

If later PRs need origin-level skip before the next row is claimed,
maintain a **separate runtime/aggregate structure**, not a join against
raw telemetry:

- Key: `destination_domain`
- Value: last observed `endpoint_origin`, `observed_at`, optional
  `retry_after_until`
- Written by the existing delivery observer (or a tiny aggregator)
- **TTL / staleness:** if `observed_at` is older than an uncalibrated
  TTL, treat the mapping as unknown and fall back to the destination
  first-contact cap only
- Shared-inbox collision: one domain may map to one origin; one origin
  may serve many domains. Caps apply on **both** keys when both are
  known. Stale mapping must not permanently pin a domain to a dead CDN
  host — TTL exists so the next successful observation can rewrite it

This map is **not** a capacity model.

### 7.3 Claim-time skip, not a new HTTP layer

No Follow-Import-specific HTTP client, no preflight, no extra header
parser beyond cached `Retry-After`. If a target is claimed, transport is
an ordinary follow.

Skipped rows stay `pending`.

### 7.4 Filling the tick

If account A's current batch **first** window is all `bad.example` in
cooldown:

- do not claim those rows
- **page** to later windows in the same batch (§5.5) before giving up
  on A
- then other batches of A, then leftover share back to the global
  account allocator

An account whose entire remainder (after the scan budget) is
cooling-down destinations gets zero this tick. Not terminal. Record
`skipped_for_backoff` and `scan_budget_exhausted` counts.

### 7.5 Claim budget is not a strict HTTP-attempt limiter

Admission limits **new** Follow Import claims. Existing Sidekiq retries
run **after** admission and do **not** re-enter the dispatcher.

```
destination claim budget  ≠  total HTTP attempt budget
```

v1 semantics:

- the dispatcher limits **new** Follow Import work
- already-enqueued `RelationshipWorker` / `DeliveryWorker` retries keep
  existing Sidekiq / Stoplight / DFT behaviour
- retry and error pressure should **suppress new admission** via
  Retry-After / error cache state and local queue pressure
  (`LocalLoadGuard` on `push`/`pull`/retry-set)
- a future **transport-level** limiter would be required if Mastodon
  ever wants a strict shared cap over new attempts **plus** retries

This design does **not** add a generic `DeliveryWorker` limiter or
change ordinary (non-import) delivery.

`queue_wait_ms` on retries includes retry delay (PR #59); it is not
remote RTT. Jobs claimed before backoff was noticed are not yanked.

### 7.6 Adaptive remote pacing (conceptual; PR G/H)

PR F ships **fixed** destination/domain budgets plus DFT /
UnavailableDomain / Retry-After cache. PR G shadows, then PR H
enforces, an adaptive controller on top of those observations. The
control law is architectural and **non-numeric**. Coefficients,
windows, minima/maxima, and latency thresholds stay **uncalibrated**
until PR #59 production telemetry is analyzed.

AIMD / slow-start is the conceptual model. **No active probing or load
testing of remote servers.**

| Observed condition | Controller action |
|---|---|
| Unknown destination / origin (no usable runtime state) | Conservative **initial** budget (same class as the fixed first-contact cap) |
| Stable successful observations | Increase **gradually** |
| 429 / `Retry-After` | Pause or strongly reduce; honour `Retry-After` (honour window still capped, uncalibrated) |
| 5xx / timeout / connection degradation | **Multiplicative decrease** |
| Recovery after decrease | Gradual increase (slow-start / additive), not an instant jump to the last high rate |
| Stale or lost runtime state | Return to the **conservative initial** state, never a learned-high state |

Reject / Accept remain follow **results**, not controller inputs.
Request-duration percentiles may later inform calibration; they are
not a v1 probe signal.

Do not implement a Node capacity score. Do not scan raw telemetry
tables on each tick; the controller reads the same runtime
cache/aggregates as §7.1–7.2.

---

## 8. Fair scheduling (account → batch → target)

Goal: two **accounts** importing at once both make visible progress. A
20_000-row import must not monopolize the instance. **One account that
splits work into many batches must not receive more throughput.**

### 8.1 Allocator

**Deficit round-robin (DRR) at the account layer**, then DRR among that
account's executable batches:

- Each tick, each executable **account** (`owner_key`) gets a **floor**
  of `min(pending_for_owner, ACCOUNT_FLOOR)` if budget remains, so a
  12-row import is not stuck behind a 20k import.
- Each account is capped at `ACCOUNT_CAP` claims in the same tick,
  **regardless of how many batches it has**.
- Remaining global budget is walked in **owner cursor** order.
- Within an account's assigned share, DRR across that account's
  executable batches with `BATCH_FLOOR` / `BATCH_CAP`. Those caps only
  split the account's share; they must not be applied as if each batch
  were a top-level peer of other users.
- An account or batch that cannot use its share (all remaining targets
  admitted-away) returns unused share to the parent pool. No deficit
  bonus that starves others.

`ACCOUNT_FLOOR`, `ACCOUNT_CAP`, `BATCH_FLOOR`, and `BATCH_CAP` are
numeric parameters (uncalibrated). Shape only: `ACCOUNT_FLOOR ≥ 1`,
`ACCOUNT_CAP` is the real multi-tenant ceiling, `BATCH_CAP ≤ ACCOUNT_CAP`.

### 8.2 Fairness is not equal wall-clock finish time

A 200-row import still finishes sooner than a 20_000-row import.
Fairness is **progress share per account**, not "everyone completes in
the same minute".

### 8.3 Per-destination sharing

A destination (and, when known, an endpoint origin) has a global cap for
the tick / window.

That cap is split across **accounts** that want it this tick (DRR on
`owner_key`), then within an account across its batches. Ten batches
from the same user targeting `popular.example` share **one** account's
slice of that destination, not ten slices.

### 8.4 Cursor durability

Store:

- last served `owner_key`
- per-owner last served `batch_id`
- optional deficit counters

Prefer a single DB dispatcher-state row (survives Redis restart) or
Redis with short TTL **and** DB rebuild. Losing the cursor only
reshuffles fairness from a conservative initial state. It must never
lose or duplicate claims. Claims are DB state.

---

## 9. Failure, backoff, retry, recovery

### 9.1 What already works (keep)

- Claim/release on enqueue failure (`queued` → `pending`).
- `RelationshipWorker` retries (8).
- Unresolved acct → `delivery_failed` / `account_unresolved`.
- `DeliveryWorker` retries (16); retries-exhausted → `delivery_failed`.
- Resolve Stoplight `source:#{domain}` (core constants; do not retune).
- Delivery Stoplight `@inbox_url` (core constants; do not retune).
- DFT / `UnavailableDomain` (core 7-day threshold; do not retune).
- Response-wait sweeper → `completed_no_response` (bookkeeping, not
  health).
- Leftover unmarked CSV recovery stays operator-driven. The dispatcher
  never re-enqueues leftover unmarked imports.

### 9.2 What the dispatcher adds

- Admit using only §7 pre-claim signals.
- Scheduler retry exhaustion is not target failure. Rows stay `pending`.
- No parallel Follow Import retry queue.

### 9.3 Recovery after a long pause

Pending rows wait. Next ticks use the current load-derived budget. No
catch-up burst (§5.2).

### 9.4 Poison / unrecoverable rows / CSV lifetime

Unrecoverable address/options: leave `pending`, do not count as a claim.
The global scheduler must **not** destroy the CSV until the batch has no
claimable pending rows (same finalize rule as
`BatchExecutionWorker#finalize_import!`).

If a batch is not executable, keep the CSV until eligibility returns or
an operator discards it.

### 9.5 Close the unpaced fallback (cutover requirement)

**Today (legacy, acceptable until global mode):**

If `FollowImportRecorder.record_batch` fails, `ImportService#import_follows!`
falls back to `import_relationships!` and bulk-enqueues follows.
`ProcessImportWorker` then destroys the Import because no
`FollowImportBatch` exists. That is exactly the burst global pacing
exists to prevent.

**End-state rule (implement in a later PR, not this documentation PR):**

| Mode | Recording fails |
|---|---|
| Legacy / global flag **off** | Existing fallback may remain temporarily. |
| **Global dispatcher authoritative** | Durable `FollowImportBatch` / `FollowImportTarget` creation is **required**. Fail / retry / **retain** the `Import`. Do **not** call `import_relationships!` for follows. Do **not** destroy the CSV just because no batch exists yet. |

`ProcessImportWorker` already retries (5) and retains the CSV on
exhaustion. Global mode uses that path instead of the unpaced fallback.

Overwrite-mode **unfollows** stay out of v1 follow-dispatch pacing.
They are **not** permanently irrelevant: they still enqueue
`Import::RelationshipWorker` and, for remotes, `ActivityPub::DeliveryWorker`,
so they are a **known remaining burst path**. Bringing
import-generated unfollows under the same flow control is a **future
completion requirement**, not an open product maybe. v1 must document
the gap; a later PR (after I, or parallel once GLOBAL is stable) should
admit unfollows through the same scheduler or an equivalent budget.

---

## 10. Durable DB-backed execution

Invariants carried forward:

- DB target state is authoritative; Sidekiq is not.
- `follow_request_uri` and state `>= queued` are persisted **before**
  the ActivityPub Follow is enqueued.
- Terminal states are never overwritten by a late callback.
- Telemetry `batch_id` / `target_id` stay nullable correlation tokens
  without FKs (PR #59).
- Pending scans keep using
  `index_follow_import_targets_on_pending_batch_id`.

**Ownership column** (implementation PR C): each batch has exactly one
first-class `dispatch_owner`: `legacy` (0) | `scheduler` (1). Set at
creation from `FOLLOW_IMPORT_DISPATCH_GLOBAL`. Scheduler queries
`dispatch_owner = scheduler`. `BatchExecutionWorker` refuses to start
a `scheduler`-owned batch. Flag flips do not rewrite stored owners.
There is no automatic drain/conversion in PR C.

Suggested indexes when implementing (not in this PR):

- pending rows by `(batch_id, destination_domain)`
- pending rows by owner (via batch), if the owner is stored denormalized

N+1 is unacceptable. One tick: a handful of aggregates, one bounded
window per served batch, claim transactions. Not one query per pending
row on the instance.

---

## 11. Observability

PR #59 remains the baseline (pre-dispatch snapshot, `0` vs `NULL`, no
payloads/accts, insert failure never fails the business path).

Tick-level facts (non-identifying):

- `tick_id`, `lease_acquired` / `lease_busy`
- `scheduler` vs `legacy_batch_worker`
- `global_budget`, `under_load`, `snapshot_source` (`live` / `last_good`
  / `conservative_baseline`)
- `executable_owner_count`, `executable_batch_count` (eligible candidate
  population, not the planned subset)
- `planned_owner_count`, `planned_batch_count` (who received a slot)
- `claimed_count`
- `skipped_for_backoff`, `skipped_not_executable`, `skipped_wrong_owner`
  (counts, not ids)
- per-tick top destinations (domain + count, capped)

Do **not** store why eligibility was false. Do **not** store
`subject_id` as a fairness dimension; `owner_key` may be hashed/truncated
if needed for privacy in logs.

Calibration still uses PR #59 SQL (request duration, 429/5xx/timeout,
dispatch vs load). Request → Accept/Reject latency is observability
only.

Aggregates (nightly per-domain/origin) remain future work. Live
admission consumes caches/aggregates, not raw scans.

---

## 12. Restart and scalability scenarios

Architectural behaviour only. No numeric thresholds.

| Scenario | Behaviour |
|---|---|
| **30-target import** | One `owner_key`, one batch. Receives at least the account floor until drained. Finishes in a small number of ticks. |
| **10_000 / 20_000-target import** | Same account floor/cap as a small import. Progresses over many ticks. No single-tick dump. Windowed selection; never load all pending rows. |
| **Many small imports (many accounts)** | Account-level DRR: each owner gets a floor when budget remains. No one account is skipped forever. |
| **Many large imports (many accounts)** | Global budget binds. Each account is capped. Instance load guard can zero the tick. |
| **One account splitting many batches** | Still **one** account share. Batch DRR only splits that share. Destination caps also split at account granularity first. |
| **Thousands of destination domains** | First-contact caps by `destination_domain`. Admission state is caches/aggregates + DFT host checks, not per-row telemetry scans. Candidate windows stay bounded. |
| **One destination, many targets** | Global destination cap; remaining rows stay pending. Other destinations (same or other accounts) fill the tick. Bounded paging skips a backoff-only prefix to reach later healthy destinations (§5.5). |
| **Legacy pass, load high, pending remain** | Guard claims 0; worker enqueues a deferred load recheck. Does not finalize. Not a tight loop. |
| **Legacy pass, not executable / unrecoverable** | Claim 0; **stop** the chain (no load recheck). |
| **Dead destination** | DFT / UnavailableDomain when host mapping is known; resolve Stoplight only if safely queryable; otherwise transport fails and the runtime cache learns. Dispatcher skips further claims for that destination. Other work continues. Historical domain-clustering is not required. |
| **Slow but healthy destination** | No Reject-based slowdown. Request-duration is **not** a v1 admission input (calibration later). First-contact cap still limits burst. Do not treat slowness as death. |
| **429 + Retry-After** | Transport records it. Runtime cache/aggregate sets `retry_after_until` on `endpoint_origin` (and mapped domain if the map is fresh). Dispatcher skips that origin until then (honour capped). DeliveryWorker retries remain. |
| **Sidekiq overload** | `LocalLoadGuard` zeros or shrinks the tick. In-flight jobs drain. No catch-up burst when load falls. |
| **Concurrent scheduler ticks** | Unique job + advisory lock. Loser observes `lease_busy` and claims 0. Target locks still prevent double-send. |
| **Redis loss** | Unique locks and Redis cursors vanish. Advisory lock + DB claims remain. Next tick: conservative fairness rebuild, current budget, no 10× catch-up. |
| **Scheduler process restart** | Lease released. Next interval starts a normal tick. Partial work is already claimed+enqueued or rolled back. |

---

## 13. Staged rollout and ownership

No stage enables Follow Gate enforcement, deny, or ordinary-Follow
changes.

**Stage 2 is not "scheduler claims zero while legacy still claims".**
That cannot protect the instance. Local-load work is a **shared guard**
(PR D shadow, PR E enforce). Until E, load descriptions are shadow only.

| Stage | Meaning | Runtime effect |
|---|---|---|
| **0 — observe** | PR #59 (done) | None. Legacy 50/30s chains. Unpaced recording fallback still exists. |
| **1 — shadow scheduler** | PR A (+ PR B plan math) | Scheduler runs single-flight, builds an account-first plan, **does not claim**. Legacy worker is the only claimer. |
| **2 — shared load guard, shadow** | PR D | Global scheduler *computes and logs* `LocalLoadGuard` and may shrink only the shadow plan. Legacy `BatchExecutionWorker` is unchanged so a shadow skip cannot stop a live chain. **No protection yet.** |
| **3 — shared load guard, enforce** | PR E | Legacy `BatchExecutionWorker` consults the shared guard **before** `select_pending_candidates` when `FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT` is on and a v2+fallback profile is configured. Positive recommendation shrinks the per-pass LIMIT. Zero due load schedules one deferred recheck (§6.2.1). The global scheduler remains shadow-only. Temporary compatibility; **not** global fairness. |
| **4 — global claiming for new imports** | PR C | New batches are `dispatch_owner = scheduler` when `FOLLOW_IMPORT_DISPATCH_GLOBAL=true`. Recording failure must not bulk-enqueue. In-flight `legacy` batches keep their chains. Scheduler cadence is real admission pacing for NEW follow additions only. |
| **5 — fixed destination admission** | PR F | Domain caps + DFT/UnavailableDomain + Retry-After cache. |
| **6 — adaptive destination, shadow then enforce** | PR G / H | After telemetry calibration. Still no Node score. |
| **7 — retire legacy** | PR I | No new `BatchExecutionWorker` chains. Drain or flip remaining `legacy` owners. Historical domain-ordering workaround can be removed when proven unused. |

Feature flags (names illustrative), all default **off**:

- `FOLLOW_IMPORT_DISPATCH_SHADOW`
- `FOLLOW_IMPORT_DISPATCH_LOAD_GUARD` (`shadow` \| `enforce`)
- `FOLLOW_IMPORT_DISPATCH_GLOBAL` (authoritative claiming + required
  recording)
- `FOLLOW_IMPORT_DISPATCH_REMOTE_ADMISSION` (`off` \| `fixed` \|
  `adaptive_shadow` \| `adaptive`)

### 13.1 Ownership during Stage 4 → 7

| Batch | Owner | Who may claim |
|---|---|---|
| Created before GLOBAL on | `legacy` | Only its existing `BatchExecutionWorker` chain |
| Created after GLOBAL on | `scheduler` | Only `DispatchScheduler` |
| Flipped by drain job | `scheduler` | Only after the legacy chain is stopped |

**Drain:** stop rescheduling a `legacy` batch (no pending
`BatchExecutionWorker` for that id, or an explicit cancel), then set
`dispatch_owner = scheduler`. Never flip while a legacy pass is in
`execute_pass`.

**Dual-claim prevention:**

- Scheduler `WHERE dispatch_owner = 'scheduler'`.
- `BatchExecutionWorker` no-ops (and does not reschedule) if
  `dispatch_owner != 'legacy'`.
- Target row locks remain.
- Turning GLOBAL **off** does not create a second chain for
  scheduler-owned batches; those wait for the scheduler or an operator
  flip back (revert runbook).

"Optional pause of new per-batch reschedules" is **not** described as
load protection. Only the shared enforced guard (Stage 3 / PR E) or
the global scheduler under load (after Stage 4) provides that.

### 13.2 PR C / Stage 4 GLOBAL rollout (implemented)

Default **off**. Deploy code and schema with
`FOLLOW_IMPORT_DISPATCH_GLOBAL=false` everywhere first.

Durable field: `follow_import_batches.dispatch_owner`
(`legacy=0`, `scheduler=1`, NOT NULL, existing rows `legacy`).
One batch = exactly one owner. Never both.

| Flag / stored owner | Who claims |
|---|---|
| GLOBAL off, new batch | `legacy` → `BatchExecutionWorker` |
| GLOBAL on, new batch | `scheduler` → periodic `DispatchScheduler` only |
| Existing row after a flag flip | stored `dispatch_owner` wins |

**Do not** infer ownership from the current ENV after the row exists.
An import retry that finds a legacy batch while GLOBAL is later true
must remain legacy. Turning GLOBAL off must not convert scheduler-owned
batches back to legacy and must not auto-enqueue `BatchExecutionWorker`
for them (dual-ownership risk during a partial rollback). Those batches
wait until the scheduler is re-enabled or an operator performs an
explicit conversion that refuses to flip while a legacy worker could
still be active. PR C does not ship that conversion.

#### Rolling deploy

1. Deploy schema/code with GLOBAL=false everywhere.
2. Finish the `dispatch_owner` migration.
3. Ensure all web / Sidekiq / scheduler processes run this revision.
4. Verify global scheduler ticks in disabled or shadow mode.
5. Configure the desired local-load profile / enforcement.
6. Enable `FOLLOW_IMPORT_DISPATCH_GLOBAL=true` consistently.
7. Restart/reload all relevant processes so feature state matches.

Do not enable GLOBAL midway through a mixed old/new application deploy.
An old process must never receive a scheduler-owned batch it does not
understand.

#### Scheduler cadence and global budget

Canonical cadence: `FOLLOW_IMPORT_DISPATCH_INTERVAL` (default 60s,
PROVISIONAL / UNCALIBRATED). Deprecated alias:
`FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL` when the canonical variable
is absent. This is now real admission pacing once GLOBAL is on. No
catch-up budget: a missed tick does not add extra budget next tick.
Restart = fresh tick, fresh load snapshot, current budget.

Global base budget: `FOLLOW_IMPORT_DISPATCH_GLOBAL_BUDGET`, default
`execution_batch_size`. Provisional / uncalibrated per-tick ceiling.
Not a remote-server capacity estimate, retry-attempt cap, or
moderation limit. Do not use `shadow_plan_budget` as the production
budget.

Local-load in GLOBAL mode reuses `LocalLoadEnforcement` /
`LocalLoadBudget` with `base = global_dispatch_budget`. Enforcement
off still binds the finite global base. Enforcement on + valid v2
profile may shrink or zero it. Runtime measurement failure uses the
explicit v2 fallback. Real claims must not depend on
`FOLLOW_IMPORT_LOCAL_LOAD_SHADOW`. A global effective budget of 0
must not discover the pending universe (`PendingBatchSource` /
target feeds / FairScheduler) or move the fairness cursor. It claims
nothing, does **not** enqueue per-batch deferred
`BatchExecutionWorker` jobs, records `planned_count=0` with
unmeasured `executable_*` as NULL, and waits for the next periodic
tick. Shadow observation (GLOBAL off) still builds a diagnostic plan
at budget 0.

#### Recording and fallback

GLOBAL recording uses the strict recorder (`record_batch!`). Failure
raises; `ProcessImportWorker` retries; the Import/CSV is retained.
The unpaced `import_relationships!` follow fallback is closed for a
new GLOBAL-owned import. Legacy mode may still use tolerant recording
and that fallback.

`BatchExecutionWorker` no-ops immediately on a scheduler-owned batch.

#### Known gaps (do not claim they are paced)

- Overwrite-generated **UNFOLLOW** operations remain a burst path.
  PR C paces imported FOLLOW additions only.
- Existing `Import::RelationshipWorker` / `ActivityPub::DeliveryWorker`
  retries do **not** re-enter `DispatchScheduler`.
  `global_dispatch_budget` is not a total HTTP attempt budget.
- No remote admission yet (destination caps, Retry-After cache, DFT,
  Stoplight, AIMD, Node capacity). Those are PR F/G/H.
- No Follow Gate / moderation coupling. `Eligibility` still defaults
  true.

#### Fairness cursor under real claims

The Redis cursor is reconstructable scheduling state, not a claim
ledger. The planner may advance past an inspected pending row
(including a permanently unrecoverable first row) so it does not
head-of-line block later work. Unclaimed pending rows remain
discoverable after wrap/rebuild. Target state is the source of truth.

The CSV may be removed only when no pending targets remain. The
existing `FollowImportCsvCleanupScheduler` is the backstop, including
zero-target scheduler-owned batches (they never appear in
`PendingBatchSource`).

---

## 14. Implementation PR sequence

Each PR is independently reviewable and revertible. No PR in this list
is this documentation PR. Numeric calibration is last, not first.

| PR | Scope | Must not |
|---|---|---|
| **A** | Global scheduler skeleton; single-flight (unique job + **session** advisory lock on a checked-out connection, unlock in `ensure`); shadow planning only; tick observations. Implementation notes: `docs/follow_import_dispatch_shadow.md`. `DispatchPlan` in A is a read-only summary (no target selection). | Claim; change `ImportService` fallback; `xact` lock around the whole tick |
| **B** | Account-first rotating RR (unit-cost DRR) + batch sub-scheduling in the **plan**; `owner_key` adapter; destination-share structure (optional cap in specs only). Shadow cursor in Redis (TTL; reconstructable; prune inactive, keep all currently-active owner/batch pointers). Lazy target feeds; pending `(batch_id, position, id)` index. Implementation: `docs/follow_import_dispatch_shadow.md`. | Claim; remote adaptive logic; ACCOUNT_FLOOR/CAP numbers |
| **C** | Authoritative global claiming for **new** imports; `dispatch_owner`; legacy/global ownership + drain; **remove unpaced recording fallback** when GLOBAL is on | Flip in-flight legacy owners implicitly; enable Follow Gate |
| **D** | `LocalLoadGuard` in the **global shadow scheduler** only: consume the pre-dispatch `LoadSnapshot`, evaluate a configured uncalibrated profile, shrink the hypothetical shadow plan, record state/percent/recommended budget. `BatchExecutionWorker` is unchanged (a shadow skip must not stop the legacy chain). Implementation: `docs/follow_import_dispatch_shadow.md`. | Enforce skip; invent production thresholds; change legacy claim rate |
| **E** | Enforce `LocalLoadGuard` on the legacy executor (default-off); shrink per-pass LIMIT or schedule one load-deferred recheck when the guard (not policy) yields zero claims. No bundled production thresholds. | Tune production envelopes as if calibrated; tight retry loops; global claiming |
| **F** | Fixed destination/domain budgets; DFT / UnavailableDomain where host mapping is known; Retry-After **runtime cache** (no raw scans); bounded candidate paging (§5.5) | Adaptive rates; Node scores; inbox Stoplight-as-if-known; unbounded 20k scans |
| **G** | Shadow adaptive destination pacing (§7.6 AIMD) from aggregates | Enforce; active probing |
| **H** | Enforce adaptive destination pacing **after** PR #59 (+ tick) calibration | Invent thresholds without data |
| **I** | Retire `BatchExecutionWorker` path; retire historical domain-ordering workaround when proven safe | Leave an unpaced `import_relationships!` follow fallback; forget import-generated unfollows as a future completion item |

Suggested flag mapping: A+B → `DISPATCH_SHADOW`; C → `DISPATCH_GLOBAL`;
D/E → `DISPATCH_LOAD_GUARD`; F–H → `DISPATCH_REMOTE_ADMISSION`.

---

## 15. Fedibird implementation notes vs a future Mastodon proposal

Portable core:

- DB-backed pending targets
- single-flight global tick + conservative/load-derived budget
- `owner_key` → batch → target fairness
- pre-claim admission limited to actually available signals
- reuse of Stoplight / DFT / Retry-After **at the layers they already
  exist**
- PR #59-style observation schema

Fedibird-only adapters:

- `owner_key_for(batch)` via `for_account` / `ModerationSubject`
- `FollowImport::ExecutionGate` → `executable?(batch)` only
- `Moderation::FollowImportRecorder` as writer; dispatcher does not read
  moderation tables

Privacy stays as in PR #59. Telemetry retention stays independent of
moderation-subject retention.

---

## 16. Remaining telemetry-dependent questions

These need production numbers or a later product choice. They do not
change the architecture above.

- Exact `under_load?` envelopes vs cleanup-scheduler (imports should
  yield to interactive `default`/`push`, but how hard?).
- Conservative baseline budget when the snapshot is missing.
- `ACCOUNT_FLOOR` / `ACCOUNT_CAP` / `BATCH_*` / destination caps.
- Whether local-only follows may use a higher cap (no remote HTTP) or
  must share the global budget.
- AIMD coefficients / windows once PR #59 has enough per-origin
  success vs 429/5xx/timeout samples (architecture in §7.6 is fixed).
- `WINDOW_SIZE` / `MAX_SCAN_TARGETS` / `MAX_SCAN_WINDOWS`.
- Legacy load-recheck interval vs `FOLLOW_IMPORT_EXECUTION_INTERVAL`.
- Import-generated unfollow flow-control shape (same scheduler vs a
  sibling budget) — **required later**, not optional; v1 only leaves
  them unpaced.
- Dispatcher `Retry-After` honour cap vs DeliveryWorker-only honour.
- Mapping-cache TTL for `destination_domain → endpoint_origin`.
- Whether Stoplight exposes a safe `source:#{domain}` colour lookup
  without side effects (if not, resolve backoff stays transport-only).
- Tick-level vs per-batch observation table shape.
- Drain automation vs operator-only flip of `dispatch_owner`.

---

## 17. Explicit non-goals (repeat)

The first implementation of this design will not:

- turn on real Follow Gate enforcement
- add deny / suspend / silence / automated restriction
- treat Follow Import, unresolved-target ratio, or Reject as a risk
  signal
- estimate remote remaining capacity or produce a Node score
- change ordinary Follow API admission
- perform content analysis or ML classification
- rewrite historical EvidenceSnapshots or other moderation artifacts
- keep an unpaced follow bulk-enqueue once GLOBAL is authoritative
- add a generic `DeliveryWorker` limiter or treat claim budget as an
  HTTP-attempt cap (retries stay outside the dispatcher in v1)

Policy may pause an import. Pacing will only see `executable? = false`.
