# Follow Import dispatch and pacing

Status: **design / pre-implementation**. This document is not an implementation
plan that has already shipped. It does not change runtime behaviour.

Numeric thresholds in this document are **provisional and uncalibrated**.
[PR #59](https://github.com/fedibird/mastodon/pull/59) added observation-only
transport and dispatch telemetry. Those measurements must be collected in
production before any number here is treated as an operational default.

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

- Dispatch is a **global, tick-driven scheduler**, not N independent per-batch
  Sidekiq chains racing each other.
- The **database target set** remains the source of truth. Sidekiq is a
  transport, not business state.
- Claim-then-enqueue stays **idempotent and row-locked**. A retry or a
  concurrent tick must not double-send a follow.
- **Eligibility** (may this import run at all?) is an external boolean. The
  pacing system must not know *why* an import is paused.
- **Local load** can skip or shrink a tick. It must not drop claimed work or
  rewrite target results.
- **Remote protection** is domain- and endpoint-aware skip/delay of *claims*,
  not a change to ordinary Follow API semantics.
- Prefer **skip this target this tick and pick another** over stalling a whole
  import or the whole dispatcher.
- Reuse existing **Stoplight**, **DeliveryFailureTracker**,
  **UnavailableDomain**, HTTP **Retry-After**, and Sidekiq retries. Do not
  invent a second circuit breaker that fights them.
- Ordinary (non-import) Follow API behaviour is unchanged in the first
  implementation.
- **Node capacity scores** are out of scope. Observed 429 / 5xx / timeout /
  Retry-After are operational backpressure facts, not a capacity model.

### Numeric parameters (must wait for PR #59 telemetry)

Treat every figure below as a placeholder label, not a ship default.

- Tick interval
- Global claim budget and how it scales with `push` / `pull` concurrency
- Per-batch floor and cap per tick
- Per-destination and per-endpoint claim caps (per tick and per sliding window)
- Local-load skip thresholds (queue size, queue latency, retry set size)
- Domain cooldown after 429 / 5xx / timeout, and how `Retry-After` is honored
- How many consecutive empty ticks before an operator alert
- Telemetry retention / aggregation windows used as limiter input

Until those are calibrated, the current env knobs remain the only production
pacing (`FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` default 50,
`FOLLOW_IMPORT_EXECUTION_INTERVAL` default 30s). They are themselves
uncalibrated.

---

## 1. Scope

In scope:

- gradual Follow Import dispatch
- local instance load protection
- remote instance protection
- fair scheduling between simultaneous imports
- domain- and endpoint-aware pacing
- failure / backoff integration
- durable DB-backed execution
- observability and staged rollout

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
                    │  how many, which targets, when      │
                    │  local budget + fairness + backoff  │
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
                    │  Stoplight                          │
                    │  DeliveryFailureTracker             │
                    │  UnavailableDomain                  │
                    └─────────────────────────────────────┘
```

**Eligibility** answers: is this batch allowed to receive claims right now?

Examples of who might set `executable? = false` later (not designed here):
an operator pause, a maintenance flag, or an unrelated policy product. The
dispatcher receives a boolean (or a skip of that `batch_id`). It must not
import risk scores, friction names, or reason codes.

**Pacing** answers: given the executable set, which pending targets are
claimed this tick, subject to local load, fairness, and remote backpressure.

**Transport** answers: resolve the acct and deliver one Follow. That path
already exists. The first implementation must not special-case Follow
creation for imports beyond the tracking / telemetry already present.

Fedibird today evaluates `FollowImport::ExecutionGate` inside
`BatchExecutionWorker` and can, if an experimental flag is on, refuse a whole
pass. That gate is a **Fedibird eligibility adapter**. It is not part of the
portable pacing core. For a future upstream proposal, replace it with a
narrow `executable?(batch)` hook (default `true`).

---

## 3. Current behaviour (problem statement)

Follow Import already has a durable execution model:

- `FollowImportBatch` / `FollowImportTarget` are the work set.
- Target states: `pending` → `queued` → `awaiting_delivery` →
  `awaiting_response` → terminal (`accepted`, `rejected`,
  `completed_no_response`, `delivery_failed`).
- `FollowImport::BatchExecutionWorker` claims up to
  `execution_batch_size` pending rows **in CSV `position` order**, marks them
  `queued`, and enqueues `Import::RelationshipWorker`.
- The worker **self-reschedules** after `execution_reschedule_in` only when
  the pass claimed at least one target.
- The CSV is not the unit of work; it is only used to recover address /
  options for a claimed row.
- Ordinary Follow delivery still goes through `FollowService` and
  `ActivityPub::DeliveryWorker` (`push` queue, retry 16).
- Resolve still goes through `Import::RelationshipWorker` (`pull` queue,
  retry 8) and a per-domain Stoplight.

What this does **not** do:

- There is **no global budget**. Two concurrent 10k imports each fire 50
  follows every 30s. Ten concurrent imports fire 500. Dispatch rate is
  `active_batches × batch_size / interval`, i.e. Sidekiq-chain fan-out, not
  an instance-level decision.
- There is **no local-load short-circuit**. PR #59 records a pre-dispatch
  `LoadSnapshot` (queue size/latency, retry size, push/pull concurrency)
  but never skips or shrinks a pass because the instance is busy.
- There is **no domain or endpoint limiter**. A CSV that lists 200 accounts
  on one host is claimed 50 at a time against that host. Position order
  often *concentrates* load on one remote when the file is grouped by
  domain (the old "sort the CSV by domain" approach is the same failure
  mode).
- Delivery-layer backoff (`Stoplight` red, `DeliveryFailureTracker`
  unavailable, HTTP 429 + `Retry-After`) happens **after** claim+enqueue.
  The executor will keep feeding the same destination into `pull`/`push`
  while those jobs sit, retry, or no-op.
- Fairness between importers is accidental. A large batch and a small batch
  each get the same 50/30s if both chains are running; a batch whose first
  50 rows are all one failing host can stall its own chain (zero claims
  after a gate-deferral, or a pile of retries) while other imports are
  unrelated.

`Scheduler::AccountsStatusesCleanupScheduler` already shows the shape we
want for *local* protection: skip the whole pass when queues/retries are
hot, compute a budget from `push` concurrency, and walk work items with a
per-item cap so one account cannot consume the tick. Follow Import should
learn from that pattern, not copy its constants.

---

## 4. Design principles

1. **Gradual by default.** An import of N follows is N claim decisions
   spread over many ticks, not N Sidekiq jobs dumped at parse time.
2. **Fair, then fast.** Simultaneous imports share one instance budget.
   No importer is entitled to the full current `batch_size` just because
   its worker woke up.
3. **Protect the local instance first.** If `default` / `push` / `pull`
   (or the retry set) are already beyond a load envelope, the tick claims
   nothing. Existing in-flight jobs finish; we do not enqueue more.
4. **Protect remotes second.** Do not claim a target whose destination or
   known endpoint is in backoff. Fill the tick with other destinations or
   other batches instead.
5. **Claim is a promise to enqueue.** If enqueue fails, release the claim
   (`queued` → `pending`) as today. Never leave a row `queued` with no job.
6. **Delivery success ≠ follow accepted.** Pacing ends at claim+enqueue
   (and at not re-claiming a row). Accept / Reject / `completed_no_response`
   stay result states, not rate-limit inputs.
7. **Reject is not a pacing signal.** A remote Reject is a follow result.
   It must not slow or pause dispatch.
8. **Absence of telemetry is not "the remote is healthy".** If we do not
   yet have request-duration or status data for an origin, use conservative
   default caps, not "unlimited until we see errors".
9. **Fail open on limiter errors.** A broken Redis/Sidekiq stats read or a
   broken telemetry query must not freeze all imports. Log, use the last
   good snapshot or the provisional default budget, and continue. A broken
   eligibility hook must not freeze all imports either (skip that batch or
   treat as executable — pick one and document it; recommendation: treat
   hook failure as executable, matching today's gate fail-open).
10. **No second source of truth.** Progress, recovery, and idempotency stay
    on `follow_import_targets`. Scheduler cursors are only "where the
    fair-share walk left off", and must be reconstructable from the DB.

---

## 5. Proposed architecture

### 5.1 Components

| Component | Responsibility | New? |
|---|---|---|
| `FollowImport::DispatchScheduler` | Periodic tick; load check; budget; fair allocation; select+claim | **Yes** |
| `FollowImport::DispatchPlan` | Pure function: snapshot + executable batches + limiter state → ordered claim list | **Yes** |
| `FollowImport::DomainBackoff` | Read-only view: destinations/origins that must not be claimed this tick | **Yes** |
| `FollowImport::Eligibility` | `executable?(batch)` adapter (default true) | Thin wrapper |
| `FollowImport::TargetTransitionService` | Claim / release / later result transitions | Existing |
| `Import::RelationshipWorker` | Resolve + `FollowService` | Existing |
| `ActivityPub::DeliveryWorker` | HTTP delivery + Stoplight + DFT | Existing |
| PR #59 telemetry | Observations for later calibration and for limiter inputs | Existing |

`BatchExecutionWorker` remains during rollout as a **legacy per-batch
chain**. The end state is: `ImportService` records the batch and does
**not** `perform_async` the per-batch worker. The scheduler discovers
pending work from the partial index on `state = pending`.

### 5.2 Tick algorithm (normative)

Each scheduler tick, in order:

1. **Snapshot local load** (same facts as `FollowImport::LoadSnapshot`:
   `default` / `push` / `pull` size and latency, `retry_size`,
   push/pull concurrency). Capture **before** any claim.
2. If `under_load?(snapshot)` → **claim zero**, record a dispatch
   observation with `claimed_count = 0` and the snapshot, exit.
3. `budget = compute_global_budget(snapshot)` (provisional formula below).
4. Load **executable** batches that have at least one `pending` target
   (`DispatchCounts.active_batches` plus eligibility).
5. `DomainBackoff.refresh` for this tick (see §7). Cheap reads only:
   in-memory last tick + Redis/DFT/Stoplight + optional recent telemetry
   aggregates. Must not scan raw observation tables on every tick.
6. `plan = DispatchPlan.build(budget, batches, backoff, cursors)`.
7. For each planned target: claim via `TargetTransitionService#mark_queued`;
   enqueue `RelationshipWorker` with the same options as today
   (`import_batch_id`, `follow_import_target_id`). On enqueue failure,
   release the claim and stop the tick (Sidekiq will retry the scheduler
   job, or the next tick will retry the row). Increment `claimed_count`
   only after a successful enqueue, as today.
8. Persist fair-share cursors (last batch id / deficit counters).
9. Write one **global** dispatch observation for the tick (extend PR #59's
   per-batch row or add a tick-level row; see §10). Do not skip telemetry
   because the tick claimed nothing.

Do not enqueue the next per-batch `BatchExecutionWorker` from this path.

### 5.3 Why a global scheduler rather than smarter per-batch workers

A per-batch worker can learn to sleep longer, but it cannot see the other
N-1 chains. Fairness and a global ceiling require a single allocator.
Cleanup-scheduler is the in-tree precedent: one worker, one budget, many
work items, skip-when-loaded.

Sidekiq remains the executor of resolve/delivery. The scheduler only
**admits** claims.

### 5.4 Selection inside a batch

Today: `ORDER BY position LIMIT batch_size`.

Proposed: build a candidate window larger than the batch's share (window
size is a numeric parameter), then **pick a diverse subset**:

- skip rows whose `destination_domain` is in backoff
- skip rows whose last known `endpoint_origin` is in backoff (when known)
- prefer destinations that have received fewer claims in this tick and in
  the current sliding window
- use `position` only as a tie-break so user-visible order stays roughly
  stable when destinations are equally eligible

This is the opposite of "sort the CSV by domain and blast that domain".
Grouping by domain is a **remote-load anti-pattern**. Interleaving is the
pacing default.

Unresolved rows still have `destination_domain` (PR #59). They participate
in destination caps. They do not yet have `endpoint_origin`; after the
first delivery observation, later rows that share that origin can be
limited more tightly.

---

## 6. Local instance load protection

Model: **admit fewer claims when the instance is already busy**. Do not
cancel in-flight `RelationshipWorker` / `DeliveryWorker` jobs. Do not mark
targets failed because we chose not to claim them.

### 6.1 Signals (already snapshotted by PR #59)

- Queue **size** and **latency** for `default`, `push`, `pull`
- Sidekiq **retry set** size
- Summed **concurrency** of processes listening to `push` / `pull`

Follow Import resolve jobs land on `pull`. Follow deliveries land on
`push`. Local follows never hit `DeliveryWorker` (already a known
telemetry gap); they still consume `pull` and `default`/`FollowService`
work.

### 6.2 Architecture (now)

Two layers, both computed from the pre-dispatch snapshot:

1. **Hard skip** — `under_load?` is true → budget 0.
2. **Soft shrink** — budget scales down as latency/size approach the skip
   envelope, so the instance eases off before falling off a cliff.

Reuse the *shape* of `AccountsStatusesCleanupScheduler#under_load?`
(per-queue size+latency, plus retry-set cap). **Do not reuse its numeric
constants.** Cleanup is a low-priority delete fan-out; Follow Import is
user-requested federation. The envelopes will differ. PR #59's
`follow_import_dispatch_observations.load_snapshot` joined to
`claimed_count` is exactly the calibration set: when did we keep claiming
50 while `push` latency was already high?

### 6.3 Provisional load envelope (uncalibrated)

Labels only — replace from telemetry:

| Signal | Cleanup scheduler today | Follow Import (placeholder) |
|---|---|---|
| `default` size / latency | 2 / 5s | *TBD* (likely higher; imports should yield to interactive work) |
| `push` size / latency | 5 / 10s | *TBD* |
| `pull` size / latency | 500 / 300s | *TBD* |
| retry set | 50_000 | *TBD* |

`compute_global_budget` placeholder:

```
budget = min(
  MAX_TICK_CLAIMS,
  PER_PUSH_THREAD * push_concurrency,
  PER_PULL_THREAD * pull_concurrency
)
# then shrink toward 0 as snapshot approaches under_load envelopes
```

`MAX_TICK_CLAIMS`, `PER_PUSH_THREAD`, and `PER_PULL_THREAD` are numeric
parameters. They are not specified as production defaults here.

### 6.4 What local load must never do

- Change Follow / Block / Mute API behaviour
- Interpret Accept/Reject
- Pause a batch "because the user looks risky"
- Delete pending targets

---

## 7. Remote instance protection (domain / endpoint-aware)

### 7.1 Two keys, two jobs

PR #59 already distinguishes:

- `destination_domain` — normalized acct domain (routing / fairness key;
  present even when unresolved)
- `endpoint_origin` — scheme + host + non-default port of the HTTP request
  that was actually sent (shared inbox, CDN, alternate host)

**Fairness and first-contact caps** use `destination_domain` (we know it
before resolve).

**Transport backoff** prefers `endpoint_origin` once observed, because that
is what 429 / Retry-After / Stoplight / DFT actually apply to. Until an
origin is known, apply only the destination-domain cap.

Do not build a "node capacity score". Do not estimate remote remaining
quota. Use:

| Input | Where it already exists | Dispatcher action |
|---|---|---|
| `DeliveryFailureTracker.available?` / `UnavailableDomain` | DeliveryWorker skip | Do not claim destinations/hosts marked unavailable |
| Stoplight red on inbox URL or resolve domain | DeliveryWorker / RelationshipWorker | Do not claim that destination this tick |
| `Retry-After` on a recent observation | transport telemetry | Do not claim that origin until `now + retry_after` (capped) |
| Recent 429 / 5xx / timeout **rates** | telemetry aggregates (not raw scan) | Temporary cooldown (numeric; uncalibrated) |

Honor `Retry-After` when present; it is the remote's explicit pacing
instruction. Cap the honor window (numeric, uncalibrated) so a pathological
header cannot freeze an origin for days inside the dispatcher. DeliveryWorker
retries still apply their own backoff independently.

### 7.2 Claim-time skip, not a new HTTP layer

The first implementation does **not** add a Follow-Import-specific HTTP
client, a custom rate-limit header parser beyond `Retry-After`, or a
preflight. If a target is claimed, transport behaves as an ordinary follow.

Backoff is **admission control**: that row stays `pending` and is
reconsidered on a later tick.

### 7.3 Filling the tick

If batch A's next 20 rows are all `bad.example` in cooldown:

- do not claim them
- still try to spend batch A's fair share on other domains in A
- leftover budget returns to the global allocator for batch B

A batch whose *entire* remainder is one cooling-down domain simply receives
zero claims this tick. That is not a terminal failure. The scheduler keeps
walking other batches. Record `skipped_for_backoff` on the tick observation
so this is visible.

### 7.4 Interaction with Sidekiq retries

Jobs already claimed+enqueued before backoff was noticed keep their existing
retry / Stoplight / DFT behaviour. The dispatcher must not yank those jobs.
It only stops **adding** more.

`queue_wait_ms` on retries includes retry delay (PR #59). Do not treat a
long wait as remote RTT.

---

## 8. Fair scheduling between simultaneous imports

Goal: two users importing at once should both make visible progress, and a
20_000-row import must not monopolize the instance or a popular destination.

### 8.1 Allocator (architecture now)

**Deficit round-robin** (or equivalent weighted fair queuing) across
executable batches:

- Each tick, each executable batch gets a **floor** of `min(pending, BATCH_FLOOR)`
  claims if budget remains (so a 12-row import is not stuck behind a 20k
  import forever).
- Each batch is capped at `BATCH_CAP` claims in the same tick.
- Remaining budget is walked in cursor order from the last served batch.
- Batches that could not use their share (all remaining targets in backoff)
  accumulate no deficit bonus that would starve others; unused share is
  returned to the pool.

`BATCH_FLOOR` and `BATCH_CAP` are numeric parameters. A reasonable
*shape* (not a default) is `FLOOR ≥ 1` and `CAP << today's 50` once a
global budget exists, because 50 × N batches is the current overload mode.

### 8.2 Fairness is not equal wall-clock finish time

A 200-row import will still finish sooner than a 20_000-row import. Fairness
means **progress share**, not "everyone completes in the same minute".

### 8.3 Per-destination fairness across batches

Two imports targeting the same remote share that destination's cap. Neither
batch may consume the whole destination budget. Split destination capacity
across batches that want it this tick (again, DRR). This is remote
protection and multi-tenant fairness at the same time.

### 8.4 Cursor durability

Store the fair-share cursor in Redis (short TTL, rebuild from `batch_id`
order on miss) or in a single dispatcher-state row. Losing the cursor must
only reshuffle fairness, never lose or duplicate claims. Claims are DB
state.

---

## 9. Failure, backoff, retry, recovery

### 9.1 What already works (keep)

- Claim/release on enqueue failure (`queued` → `pending`).
- `RelationshipWorker` retries (8) for transient resolve/follow errors.
- Unresolved acct → `delivery_failed` / `account_unresolved` (terminal).
- `DeliveryWorker` retries (16); retries-exhausted → delivery tracking
  failed → target `delivery_failed`.
- Stoplight on inbox URL (threshold 10, cooldown 60s — Mastodon core
  constants; this design does not retune them).
- `DeliveryFailureTracker` / `UnavailableDomain` after sustained daily
  failures (7-day threshold — core constant; do not retune here).
- Response-wait sweeper: `awaiting_response` past
  `FollowImport::ExecutionPolicy.response_wait` (48h) →
  `completed_no_response`. That is **import bookkeeping**, not a remote
  health signal.
- Leftover unmarked CSV recovery stays operator-driven
  (`follow_import:legacy_cleanup`). The dispatcher must never re-enqueue
  leftover unmarked imports.

### 9.2 What the dispatcher adds

- **Do not claim** into a destination/origin that transport is already
  suppressing (DFT unavailable, Stoplight red, honoured Retry-After).
- **Do not treat** Sidekiq retry exhaustion of the *scheduler* as target
  failure. Targets stay `pending`.
- **Do not** create a parallel retry queue for Follow Import. One job
  pipeline.

### 9.3 Recovery after a long pause

If the instance was under load for an hour, pending rows wait. When load
returns, the next ticks resume from the fair-share cursor and backoff map.
No catch-up burst: budget is still the load-derived budget. "We were idle,
so dump 5_000 follows" is forbidden.

### 9.4 Poison / unrecoverable rows

Address/options unrecoverable from CSV (already: leave `pending`, do not
count as a claim). After the CSV is destroyed (today: when the per-batch
chain sees no pending left), unrecoverable rows should already be gone or
terminal. The global scheduler must **not** destroy the CSV until the batch
has no claimable pending rows, same finalize rule as
`BatchExecutionWorker#finalize_import!`.

If a batch is not executable, keep the CSV until eligibility returns or an
operator discards it. Pacing does not invent a discard policy.

---

## 10. Durable DB-backed execution

Invariants carried forward:

- DB target state is authoritative; Sidekiq is not.
- `follow_request_uri` and state `>= queued` are persisted **before** the
  ActivityPub Follow is enqueued (Accept/Reject may arrive first).
- Terminal states are never overwritten by a late callback.
- `batch_id` / `target_id` on telemetry rows stay nullable correlation
  tokens without foreign keys (PR #59). Dispatcher state must not require
  telemetry rows to exist.
- Global pending / active-batch counts keep using
  `index_follow_import_targets_on_pending_batch_id`. Selection queries must
  stay on `state = pending` (and `batch_id` / `destination_domain`) so
  historical terminals do not dominate scans.

Suggested indexes when implementing (not in this PR):

- `(destination_domain, state)` or a partial index on pending rows by
  domain, so "next diverse pending target in batch B" is not a sequential
  filter of `ORDER BY position`.
- No unbounded `SELECT` of all pending rows for a 20k batch on every tick.
  Use a bounded window + skip already-seen ids in that tick.

N+1 is unacceptable. One tick should be a handful of aggregate queries +
one window query per served batch + one claim transaction per target (or a
small batched claim). Not "one query per pending row in the instance".

---

## 11. Observability

PR #59 is the baseline. The dispatcher must keep it honest:

- Load snapshot **before** claims.
- `0` means observed zero; `NULL` means measurement unavailable.
- No payload bodies, inbox paths, acct lists, or profile text.
- Telemetry insert failure never fails the business path.

### 11.1 Additional facts the tick should record

Extend dispatch observations (or add a tick-level row) with structured
metadata, still non-identifying:

- `tick_id` / `scheduler` vs `legacy_batch_worker`
- `global_budget`, `under_load`
- `executable_batch_count` vs `active_batch_count`
- `claimed_count` (already)
- `skipped_for_backoff`, `skipped_not_executable` (counts, not ids)
- per-tick top destinations claimed (domain + count only, capped list)

Do **not** store why eligibility was false.

### 11.2 Calibration queries (already sketched in PR #59)

Reuse and extend:

- claimed_count vs pre-dispatch `push`/`pull` latency (local envelope)
- 429 / 5xx / timeout / Retry-After rates by `endpoint_origin`
- request-duration percentiles by origin (never worker `duration_ms` as
  remote RTT)
- `active_batch_count` vs total claims per minute (fairness / fan-out)
- request → Accept/Reject latency is **observability only**. It is not a
  backoff input and not a nuisance signal.

Aggregation of raw transport rows (nightly per-domain/origin counters) is
still future work from PR #59. The dispatcher should consume **aggregates**,
not re-scan raw rows every tick. Until aggregates exist, live backoff is
limited to DFT / Stoplight / the last N tick-local 429/Retry-After cache —
not a table scan.

---

## 12. Staged rollout

No stage enables Follow Gate enforcement, deny, or ordinary-Follow changes.

| Stage | What ships | Dispatch effect |
|---|---|---|
| **0 — observe** | PR #59 (done) | None. Current 50/30s chains. |
| **1 — shadow plan** | Scheduler computes plan + logs/records it; **still claims via the old per-batch worker** | None. Compare "what the plan would have claimed" to what the chain claimed. |
| **2 — local-load skip** | Scheduler may run ticks that claim **zero** when `under_load?`; optional pause of *new* per-batch reschedules when under load | Slows only when the instance is already hot. |
| **3 — global fair budget** | Scheduler is the only claimer for new batches; legacy worker off for new imports | Fair share + global ceiling. No domain limiter yet. |
| **4 — live backoff skip** | DFT / Stoplight / Retry-After / recent 429 skip at claim time | Remote protection without capacity scores. |
| **5 — calibrated numbers** | Replace provisional envelopes using PR #59 (+ tick) telemetry | Same architecture, different constants. |
| **6 — retire legacy chain** | No `BatchExecutionWorker.perform_async` from `ImportService` | Single dispatcher. |

Each stage is independently revertible. Stage 1 must run long enough to
show the plan is not empty when work exists and does not propose
double-claims.

Feature flags (names illustrative):

- `FOLLOW_IMPORT_DISPATCH_SHADOW` (stage 1)
- `FOLLOW_IMPORT_DISPATCH_LOAD_GUARD` (stage 2)
- `FOLLOW_IMPORT_DISPATCH_GLOBAL` (stage 3)
- `FOLLOW_IMPORT_DISPATCH_REMOTE_BACKOFF` (stage 4)

Defaults: all off until an operator opts in. Same spirit as today's
`FOLLOW_IMPORT_GATE_ENFORCEMENT` default off — except gate enforcement is
**not** part of this design's rollout.

---

## 13. Fedibird implementation notes vs a future Mastodon proposal

Portable core (safe to describe upstream):

- DB-backed pending targets
- global tick + load-derived budget
- fair share across imports
- domain/endpoint admission control
- reuse of Stoplight / DFT / Retry-After
- observation schema from PR #59 (or an equivalent)

Fedibird-specific adapters (keep out of the portable core):

- `FollowImportBatch.subject` → `ModerationSubject` ownership. Factor to a
  neutral `account_id` (or equivalent) before or when upstreaming. PR #59
  already called this out for telemetry FKs.
- `FollowImport::ExecutionGate` / Adaptive Follow Gate. Expose only
  `executable?(batch)`.
- `Moderation::FollowImportRecorder` as the batch writer. Recording can
  stay; the dispatcher must not read moderation tables.

Privacy / data minimization stays as in PR #59: structured metadata, no
content, no bulk acct dumps, telemetry retention independent of any
moderation-subject retention.

---

## 14. Open questions (do not block the architecture)

These need production numbers or a later product choice; they do not change
§5.

- Exact `under_load?` envelopes versus cleanup-scheduler (imports should
  yield to interactive `default`/`push` work, but how hard?).
- Whether local-only follows should have a separate, higher cap (no remote
  HTTP) or share the same global budget (they still cost `pull` + DB).
- Whether overwrite-mode **unfollows** stay fire-and-forget
  (`enqueue_follow_overwrite_unfollows!` today) or join the same budget.
  Recommendation: leave unfollows out of v1 pacing (out of scope for
  gradual follow *dispatch*), but document that they can still spike `pull`.
- How long to honour `Retry-After` in the dispatcher vs letting
  DeliveryWorker be the only consumer.
- Tick-level vs per-batch dispatch observation schema (extend vs new table).
- Whether stage 3 should drain in-flight legacy chains before taking over,
  or only apply to batches created after the flag.

---

## 15. Explicit non-goals (repeat)

The first implementation of this design will not:

- turn on real Follow Gate enforcement
- add deny / suspend / silence / automated restriction
- treat Follow Import, unresolved-target ratio, or Reject as a risk signal
- estimate remote remaining capacity or produce a Node score
- change ordinary Follow API admission
- perform content analysis or ML classification
- rewrite historical EvidenceSnapshots or other moderation artifacts

Policy may pause an import. Pacing will only see `executable? = false`.
