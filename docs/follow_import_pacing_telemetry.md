# Follow Import pacing telemetry

Status: observation only.
Purpose: accumulate a real-operation baseline so a future Follow Import
dispatch-pacing / backpressure / fairness design can be calibrated from
measured transport and local Sidekiq load.

This is **not** a moderation ledger, an Adaptive Follow Gate input, or an
abuse-detection feature. Reject remains a Follow Import result state. It is
not interpreted here as a nuisance signal.

This document does **not** introduce adaptive pacing, token buckets, global
budgets, per-domain rate limits, fairness, automatic backoff, Follow Gate
coupling, Node capacity scores, or removal of the existing CSV / domain-sort
hack.

## No moderation decision/signal coupling

Telemetry does **not** consume Adaptive Follow Gate proposals, risk scores,
block/mute/report counts, or Reject-as-abuse interpretation.

Batch/target *ownership* still goes through `Moderation::FollowImportRecorder`
and `ModerationSubject`. That is a Fedibird implementation legacy: the rows
were created on the moderation ledger because Follow Import was recorded there
first. Factor that into a neutral Follow Import layer before or when
upstreaming the pacing work. This PR does not perform that refactor.

`batch_id` and `target_id` on telemetry rows are nullable correlation tokens
**without foreign keys**. Telemetry retention must not be tied to
moderation-subject retention.

## What is collected

Technical facts only:

- dispatch volume (candidates / claimed / batch + global pending / active batches)
- local Sidekiq load **before** the pass claims or enqueues work
- destination domain (from the imported acct)
- actual HTTP endpoint origin (scheme + host + non-default port)
- resolve-path duration and outcome (not remote HTTP unless separately observed)
- ActivityPub worker duration **and** actual HTTP request duration
- push-queue wait (from `delivery_tracking.enqueued_at`) and pull-queue wait
  (from `FollowImportTarget.queued_at`)
- HTTP status, Retry-After, error class
- enough timestamps to derive request → Accept / request → Reject later

## What is never stored

- ActivityPub payload body
- full inbox URL path / query
- imported acct strings or usernames
- profile data
- extra source account IDs beyond the existing batch/target references
- moderation risk scores, block/mute/report counts
- negative-response interpretation

## Schema

### `follow_import_targets.destination_domain`

Nullable routing metadata written when the target is recorded onto the batch.

- Derived from the CSV acct with the same bare-local default as
  `FollowImportTarget.key_hash` (blank domain → `Rails.configuration.x.local_domain`).
- Normalized with `TagManager#normalize_domain`.
- Username is discarded.
- Unresolved targets still keep a domain.
- Original CSV `position` is unchanged; this column is **not** a sort key.

### `follow_import_transport_observations`

One row per observed attempt.

| column | meaning |
|---|---|
| `phase` | `resolve_account` or `activitypub_delivery` |
| `destination_domain` | acct-derived routing domain |
| `endpoint_origin` | origin of the HTTP request actually sent |
| `sidekiq_queue` / `sidekiq_job_id` | worker identity |
| `enqueued_at` | dispatch origin (see below); NULL if unknown |
| `started_at` / `finished_at` / `duration_ms` | **worker** wall time |
| `request_started_at` / `request_finished_at` / `request_duration_ms` | actual HTTP attempt; **NULL if no request** |
| `queue_wait_ms` | `started_at - enqueued_at` when both are present; else NULL |
| `outcome` | coarse technical bucket (see below) |
| `http_status` | actual status when a response was received |
| `retry_after_seconds` | parsed `Retry-After` when safely parseable |
| `error_class` | exception class name when one escaped to the worker |
| `metadata` | schema version plus non-identifying facts |

`0` on a duration/count means an observed zero. **NULL means the measurement
was unavailable or invalid** (including a backwards clock interval). Telemetry
code must not encode a failed or interrupted count as `0`.

`destination_domain` and `endpoint_origin` are different ideas. A shared inbox,
a CDN, or an alternate host can make them diverge (`alice@example.social` vs
`https://inbox.example.social:8443`).

#### Timing fields (do not collapse them)

**Worker duration** (`started_at` → `finished_at` / `duration_ms`) includes
DeliveryFailureTracker, Account lookup, URL setup, Stoplight, RequestPool wait,
signing, and the HTTP attempt. Do **not** treat it as remote response latency.

**Request duration** is captured inside `request_pool.with`, immediately before
`build_request(...).perform`, and closed in `ensure` so timeouts and connection
errors still get `request_finished_at`. Availability suppression and
Stoplight-open (`RedLight`) leave all `request_*` columns NULL.

**Push queue wait** (`activitypub_delivery`): `FollowService` stamps
`delivery_tracking.enqueued_at` (ISO8601) immediately before
`ActivityPub::DeliveryWorker.perform_async` for Follow Import deliveries only.
Ordinary deliveries are unchanged. On Sidekiq retry the original enqueue
timestamp is reused, so `queue_wait_ms` includes retry delay.

**Pull queue wait** (`resolve_account`): `FollowImportTarget.queued_at` is
written when `BatchExecutionWorker` claims the target, immediately before
`Import::RelationshipWorker.perform_async`. Resolution telemetry uses that as
`enqueued_at`. It measures claim → RelationshipWorker start, **not** remote
HTTP. RelationshipWorker retries keep the original `queued_at`.

### `follow_import_dispatch_observations`

One row per `FollowImport::BatchExecutionWorker` pass, including passes that
claim nothing.

`load_snapshot` is captured at the **start** of the pass, before any target is
claimed or any `RelationshipWorker` job is enqueued. Using a post-dispatch
snapshot would contaminate the baseline with work this pass just created.

| column | meaning |
|---|---|
| `batch_pending_before` | this batch's pending targets at pre-dispatch |
| `batch_pending_after` | this batch's pending targets after the pass |
| `pending_count` | same as `batch_pending_after` (legacy alias) |
| `global_pending_count` | pending targets across all batches (pre-dispatch) |
| `active_batch_count` | distinct batches with at least one pending target (pre-dispatch) |
| `candidate_count` | pending rows selected for this pass; NULL if selection failed |
| `claimed_count` | successful claim+enqueue count so far; incremented after each enqueue |
| `pass_error_class` | exception class if the pass raised (the error is still re-raised) |

These are scheduling/load facts. They do not store account or subject ids.
`claimed_count` plus `observed_at` is enough to derive a global dispatch rate
later. A raise after some successful enqueues still records the partial
`claimed_count`; it does not write `0`.

Global pending / active-batch counts use
`index_follow_import_targets_on_pending_batch_id` — a **partial** index on
`batch_id` for `state = pending` only. The older `(batch_id, state)` index is
prefix-batch and cannot cheaply answer "all pending rows" once historical
terminal targets dominate the table. The partial index stays compact (only
the live dispatchable set) and supports both `COUNT(*)` and
`COUNT(DISTINCT batch_id)` filtered to pending.

`execution_policy` snapshots the knobs in force at that moment:

- `execution_batch_size`
- `execution_reschedule_in` (seconds)
- `gate_enforcement_enabled`
- telemetry `schema` / `schema_version`
- `load_snapshot_timing` = `pre_dispatch`

so later env changes remain reconstructable.

This PR **never** skips or slows a pass because the instance is under load.

## Instrumented paths

1. `Moderation::FollowImportRecorder#record_batch` — persist `destination_domain`.
2. `Import::RelationshipWorker` — `resolve_account` observation only when
   `follow_import_target_id` is present on a follow.
3. `FollowService#request_follow!` — stamp `enqueued_at` on Follow Import
   `delivery_tracking` only.
4. `ActivityPub::DeliveryWorker` — `activitypub_delivery` observation only when
   `delivery_tracking.type == follow_import_target`.
5. `FollowImport::BatchExecutionWorker` — pre-dispatch load + backlog, then one
   dispatch observation per pass.

Ordinary (non-import) resolution and ActivityPub delivery are not observed.

Telemetry insert failure, Sidekiq-stats failure, and unparseable endpoint /
Retry-After / enqueue timestamps are swallowed by `FollowImport::Telemetry`
after a rate-limited warning. They must not fail or retry the business path.

## Outcomes and limitations

### Account resolution

`Import::RelationshipWorker` wraps `ResolveAccountService` in a Stoplight whose
fallback is `{ nil }`. A circuit-open fallback and a genuine not-found are
therefore **indistinguishable**. Both are recorded as
`unresolved_or_unavailable`. The metadata flag `stoplight_wrapped` only records
whether the remote-domain Stoplight path ran; it is not a suppression verdict.

`duration_ms` on `resolve_account` is **end-to-end resolution-path duration**.
`ResolveAccountService` may finish from a local/cached account as well as by
remote discovery. Do **not** interpret that value as remote HTTP response
latency. This PR does not instrument ResolveAccountService's HTTP calls.

Raised exceptions that escape the worker are recorded as `unknown_exception`
with `error_class` and then re-raised (existing retry behaviour).

### ActivityPub delivery

`DeliveryWorker`'s `@performed` is set for HTTP 2xx **and** for unsalvageable
responses (the worker does not retry those). Telemetry therefore stores the
real `http_status` and does **not** treat `@performed == true` as success.
`metadata.performed` is kept as a raw fact for analysts.

Outcomes written when they can be established without guessing:

| outcome | when |
|---|---|
| `http_success` | response status is 2xx |
| `http_retryable` | worker raised `Mastodon::UnexpectedResponseError` (current retry path) |
| `http_unsalvageable` | a non-2xx response was accepted without raising |
| `timeout` | `HTTP::TimeoutError` |
| `connection_failure` | `HTTP::ConnectionError` or `OpenSSL::SSL::SSLError` |
| `availability_suppression` | `DeliveryFailureTracker` skipped the request |
| `circuit_or_stoplight_interruption` | `Stoplight::Error::RedLight` |
| `unknown_exception` | any other escaped error (`error_class` stored) |
| `unknown` | no response, no error, no skip reason |

Existing retry / Stoplight / `DeliveryFailureTracker` decisions are unchanged.

### Follow response latency

`FollowImportTarget` already has:

- `delivered_at` — set when delivery bookkeeping marks `awaiting_response`
- `completed_at` — set when the target becomes `accepted` or `rejected`
  (also `completed_no_response` / `delivery_failed`)

No extra response-timestamp column is added. `completed_at` is the Accept /
Reject receive time for those states.

Accept/Reject can race **ahead** of the delivery-success callback, so
`delivered_at` may be null and `completed_at` may precede worker `finished_at`.
Analysts should JOIN the target to `activitypub_delivery` observations and use
`request_started_at` (else `enqueued_at`) as the origin — not `finished_at` —
so a bookkeeping race does not produce a negative latency by itself.

## Current baseline execution policy

Uncalibrated, env-overridable, **not** load-aware:

- `FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` (default 50)
- `FOLLOW_IMPORT_EXECUTION_INTERVAL` (default 30 seconds)
- `FOLLOW_IMPORT_GATE_ENFORCEMENT` (default off; gate is logged, not applied)
- `FOLLOW_IMPORT_DISPATCH_SHADOW` (default off; global scheduler observes only)
- `FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET` (diagnostic shadow plan size;
  default = execution batch size; does **not** control real execution)

This PR does not change those values or add an under-load short-circuit.

### `follow_import_dispatch_tick_observations`

One row per **global** `FollowImport::DispatchScheduler` tick (PR A
shadow skeleton). This is not a per-batch
`BatchExecutionWorker` pass. `claimed_count` is always `0` while the
scheduler is shadow-only.

| column | meaning |
|---|---|
| `observed_at` | tick start (UTC) |
| `tick_id` | opaque uuid for the tick |
| `scheduler_mode` | `shadow` in PR A |
| `lease_acquired` | whether the PostgreSQL session advisory lease was held |
| `outcome` | `lease_busy` / `shadow_observed` / `shadow_error` |
| `global_pending_count` | pending targets across batches; NULL if unmeasured |
| `active_batch_count` | distinct batches with a pending target; NULL if unmeasured |
| `claimed_count` | always 0 while shadow-only |
| `planned_count` | account-first simulation size; NULL if planning was not attempted |
| `executable_owner_count` / `executable_batch_count` / `unique_destination_count` | plan aggregates; NULL if not planned |
| `skipped_missing_owner_count` | batches skipped because no owner key could be derived |
| `fairness_state_source` | `redis` / `default` / `reset` / `persist_failed` |
| `load_snapshot` | Sidekiq load facts, or NULL if capture failed |
| `execution_config` | execution + shadow-flag snapshot, including `dispatch_shadow_interval` from `FollowImport::ExecutionPolicy` (same ENV/default as `config/sidekiq.yml`) |
| `error_class` | exception class for `shadow_error` |
| `metadata` | schema version plus non-identifying facts |

See `docs/follow_import_dispatch_shadow.md`. The shadow scheduler must
not store handles, usernames, payloads, inbox paths, target accts, or
moderation scores. Load snapshots are not interpreted as
NORMAL/BUSY/OVERLOADED here.

## Expected row volume

Rough order of magnitude, not a quota:

- 1 `resolve_account` row per RelationshipWorker execution of a Follow Import
  target (including Sidekiq retries; default retry 8).
- 1 `activitypub_delivery` row per DeliveryWorker execution of a tracked
  Follow Import delivery (including retries; default retry 16).
- 1 dispatch row per BatchExecutionWorker pass
  (`ceil(pending / execution_batch_size)` while the chain makes progress,
  plus idle/final passes).

Example: a 10_000-target remote import with 1.2 delivery attempts and one
successful resolve each ≈ 10k resolve + 12k delivery + ~200 dispatch ≈ 22k
rows. A high-retry domain multiplies delivery rows up to ~17× that target.

Time-oriented indexes (`started_at`, `observed_at`, and
`phase + domain/origin + started_at`) exist so later cleanup/aggregation can
delete or roll up raw rows by window without a sequential scan. The pending
`batch_id` partial index exists so dispatch telemetry itself does not become
a sequential-scan load on `follow_import_targets`.

### Future cleanup / aggregation (not implemented)

Suggested later work, not part of this PR:

1. Nightly aggregate to per-`destination_domain` / per-`endpoint_origin`
   counters (attempts, status histogram, **request** duration percentiles,
   Retry-After).
2. Drop or archive raw rows older than an operator-chosen window
   (for example 14–30 days) independently of moderation-subject retention.
3. Do **not** roll these facts into Node capacity scores until a later
   pacing design explicitly asks for that.

## Sample read-only SQL

### A. Per destination domain (actual HTTP request duration)

```sql
SELECT
  destination_domain,
  COUNT(*) AS attempts,
  COUNT(*) FILTER (WHERE outcome = 'http_success') AS http_successes,
  COUNT(*) FILTER (WHERE outcome = 'http_retryable') AS http_retryable,
  COUNT(*) FILTER (WHERE outcome = 'http_unsalvageable') AS http_unsalvageable,
  COUNT(*) FILTER (WHERE outcome IN ('timeout', 'connection_failure')) AS transport_errors,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY request_duration_ms)
    FILTER (WHERE request_duration_ms IS NOT NULL) AS p50_request_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY request_duration_ms)
    FILTER (WHERE request_duration_ms IS NOT NULL) AS p95_request_ms
FROM follow_import_transport_observations
WHERE phase = 'activitypub_delivery'
GROUP BY destination_domain
ORDER BY attempts DESC;
```

Do **not** use `duration_ms` here — that is worker wall time.

Status histogram:

```sql
SELECT destination_domain, http_status, COUNT(*) AS n
FROM follow_import_transport_observations
WHERE phase = 'activitypub_delivery'
GROUP BY 1, 2
ORDER BY 1, 2;
```

### B. Per endpoint origin

```sql
SELECT
  endpoint_origin,
  COUNT(*) AS attempts,
  COUNT(*) FILTER (WHERE http_status = 429) AS count_429,
  COUNT(*) FILTER (WHERE http_status = 429)::float / NULLIF(COUNT(*), 0) AS rate_429,
  COUNT(*) FILTER (WHERE http_status BETWEEN 500 AND 599) AS count_5xx,
  COUNT(*) FILTER (WHERE http_status BETWEEN 500 AND 599)::float / NULLIF(COUNT(*), 0) AS rate_5xx,
  COUNT(*) FILTER (WHERE outcome = 'timeout') AS count_timeout,
  COUNT(*) FILTER (WHERE outcome = 'timeout')::float / NULLIF(COUNT(*), 0) AS rate_timeout,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY request_duration_ms)
    FILTER (WHERE request_duration_ms IS NOT NULL) AS p50_request_ms,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY retry_after_seconds)
    FILTER (WHERE retry_after_seconds IS NOT NULL) AS p50_retry_after_seconds,
  MAX(retry_after_seconds) AS max_retry_after_seconds
FROM follow_import_transport_observations
WHERE phase = 'activitypub_delivery'
  AND endpoint_origin IS NOT NULL
GROUP BY endpoint_origin
ORDER BY count_429 DESC, attempts DESC;
```

### C. Dispatch pass vs pre-dispatch local load

```sql
SELECT
  d.id,
  d.batch_id,
  d.observed_at,
  d.candidate_count,
  d.claimed_count,
  d.batch_pending_before,
  d.batch_pending_after,
  d.global_pending_count,
  d.active_batch_count,
  (d.load_snapshot -> 'queues' -> 'default' ->> 'latency')::float AS default_latency,
  (d.load_snapshot -> 'queues' -> 'push' ->> 'latency')::float AS push_latency,
  (d.load_snapshot -> 'queues' -> 'pull' ->> 'latency')::float AS pull_latency,
  (d.load_snapshot -> 'queues' -> 'push' ->> 'size')::int AS push_size,
  (d.execution_policy ->> 'execution_batch_size')::int AS execution_batch_size
FROM follow_import_dispatch_observations d
ORDER BY d.observed_at DESC;
```

### D. Request → Accept / Reject latency

Use the HTTP request start (else enqueue time) as the origin, not worker
`finished_at`.

```sql
SELECT
  t.destination_domain,
  t.state,
  EXTRACT(EPOCH FROM (
    t.completed_at - COALESCE(d.request_started_at, d.enqueued_at)
  )) AS response_latency_seconds
FROM follow_import_targets t
JOIN LATERAL (
  SELECT o.request_started_at, o.enqueued_at
  FROM follow_import_transport_observations o
  WHERE o.target_id = t.id
    AND o.phase = 'activitypub_delivery'
    AND o.outcome = 'http_success'
  ORDER BY COALESCE(o.request_started_at, o.enqueued_at) ASC NULLS LAST
  LIMIT 1
) d ON TRUE
WHERE t.state IN ('accepted', 'rejected')
  AND t.completed_at IS NOT NULL;
```

A remaining negative value means Accept/Reject was recorded before this
request started (for example a prior attempt). Those rows are still valid.

## Known observation gaps

- Local follows that never hit `ActivityPub::DeliveryWorker`.
- Non-Follow-Import ActivityPub deliveries and relationship imports.
- Stoplight-open vs not-found during resolve (see above).
- Resolve path has no lower-level HTTP span (`request_*` stays NULL).
- Shared-inbox / alternate-host mapping is visible only as
  `destination_domain` ≠ `endpoint_origin`, not as a graph.
- Sidekiq retry index is not stored (only `sidekiq_job_id`). On retry,
  `enqueued_at` is the original enqueue, so `queue_wait_ms` includes retry delay.
- HTTP bodies, inbox paths, and remote error text are intentionally absent.
- No Node-level aggregation yet.
