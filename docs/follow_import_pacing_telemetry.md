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

## What is collected

Technical facts only:

- dispatch volume (candidates / claimed / remaining pending)
- local Sidekiq load (queue size/latency, retry size, push/pull concurrency)
- destination domain (from the imported acct)
- actual HTTP endpoint origin (scheme + host + non-default port)
- resolve duration and outcome
- ActivityPub delivery duration, HTTP status, Retry-After, error class
- enough timestamps to derive delivery → Accept / delivery → Reject later

## What is never stored

- ActivityPub payload body
- full inbox URL path / query
- imported acct strings or usernames
- profile data
- extra source account IDs beyond the existing batch/target references
- moderation risk scores, block/mute/report counts
- negative-response interpretation

`batch_id` and `target_id` on telemetry rows are nullable correlation tokens
**without foreign keys**. Deleting a `ModerationSubject` / batch does not
cascade into these tables, and telemetry retention must not be tied to
moderation-subject retention.

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
| `started_at` / `finished_at` / `duration_ms` | wall time |
| `outcome` | coarse technical bucket (see below) |
| `http_status` | actual status when a response was received |
| `retry_after_seconds` | parsed `Retry-After` when safely parseable |
| `error_class` | exception class name when one escaped to the worker |
| `metadata` | schema version plus non-identifying facts |

`destination_domain` and `endpoint_origin` are different ideas. A shared inbox,
a CDN, or an alternate host can make them diverge (`alice@example.social` vs
`https://inbox.example.social:8443`).

### `follow_import_dispatch_observations`

One row per `FollowImport::BatchExecutionWorker` pass, including passes that
claim nothing.

`execution_policy` snapshots the knobs in force at that moment:

- `execution_batch_size`
- `execution_reschedule_in` (seconds)
- `gate_enforcement_enabled`
- telemetry `schema` / `schema_version`

so later env changes remain reconstructable.

`load_snapshot` is read-only. This PR **never** skips or slows a pass because
the instance is under load.

## Instrumented paths

1. `Moderation::FollowImportRecorder#record_batch` — persist `destination_domain`.
2. `Import::RelationshipWorker` — `resolve_account` observation only when
   `follow_import_target_id` is present on a follow.
3. `ActivityPub::DeliveryWorker` — `activitypub_delivery` observation only when
   `delivery_tracking.type == follow_import_target`.
4. `FollowImport::BatchExecutionWorker` — one dispatch/load observation per pass.

Ordinary (non-import) resolution and ActivityPub delivery are not observed.

Telemetry insert failure, Sidekiq-stats failure, and unparseable endpoint /
Retry-After values are swallowed by `FollowImport::Telemetry` after a
rate-limited warning. They must not fail or retry the business path.

## Outcomes and limitations

### Account resolution

`Import::RelationshipWorker` wraps `ResolveAccountService` in a Stoplight whose
fallback is `{ nil }`. A circuit-open fallback and a genuine not-found are
therefore **indistinguishable**. Both are recorded as
`unresolved_or_unavailable`. The metadata flag `stoplight_wrapped` only records
whether the remote-domain Stoplight path ran; it is not a suppression verdict.

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
`delivered_at` may be null and `completed_at` may precede a delivery
observation's `finished_at`. Analysts should JOIN the target to
`activitypub_delivery` observations (prefer the earliest `http_success`)
rather than assume `delivered_at` is always present.

## Current baseline execution policy

Uncalibrated, env-overridable, **not** load-aware:

- `FOLLOW_IMPORT_EXECUTION_BATCH_SIZE` (default 50)
- `FOLLOW_IMPORT_EXECUTION_INTERVAL` (default 30 seconds)
- `FOLLOW_IMPORT_GATE_ENFORCEMENT` (default off; gate is logged, not applied)

This PR does not change those values or add an under-load short-circuit.

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

### Future cleanup / aggregation (not implemented)

Suggested later work, not part of this PR:

1. Nightly aggregate to per-`destination_domain` / per-`endpoint_origin`
   counters (attempts, status histogram, duration percentiles, Retry-After).
2. Drop or archive raw rows older than an operator-chosen window
   (for example 14–30 days) independently of moderation-subject retention.
3. Do **not** roll these facts into Node capacity scores until a later
   pacing design explicitly asks for that.

## Sample read-only SQL

### A. Per destination domain

```sql
SELECT
  destination_domain,
  COUNT(*) AS attempts,
  COUNT(*) FILTER (WHERE outcome = 'http_success') AS http_successes,
  COUNT(*) FILTER (WHERE outcome = 'http_retryable') AS http_retryable,
  COUNT(*) FILTER (WHERE outcome = 'http_unsalvageable') AS http_unsalvageable,
  COUNT(*) FILTER (WHERE outcome IN ('timeout', 'connection_failure')) AS transport_errors,
  jsonb_object_agg(http_status, status_count) FILTER (WHERE http_status IS NOT NULL) AS http_status_distribution,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) AS p50_duration_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95_duration_ms
FROM (
  SELECT
    destination_domain,
    outcome,
    http_status,
    duration_ms,
    COUNT(*) OVER (PARTITION BY destination_domain, http_status) AS status_count
  FROM follow_import_transport_observations
  WHERE phase = 'activitypub_delivery'
) attempts
GROUP BY destination_domain
ORDER BY attempts DESC;
```

A simpler status histogram without the window:

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
  percentile_cont(0.50) WITHIN GROUP (ORDER BY retry_after_seconds)
    FILTER (WHERE retry_after_seconds IS NOT NULL) AS p50_retry_after_seconds,
  MAX(retry_after_seconds) AS max_retry_after_seconds
FROM follow_import_transport_observations
WHERE phase = 'activitypub_delivery'
  AND endpoint_origin IS NOT NULL
GROUP BY endpoint_origin
ORDER BY count_429 DESC, attempts DESC;
```

### C. Dispatch pass vs local load

```sql
SELECT
  d.id,
  d.batch_id,
  d.observed_at,
  d.candidate_count,
  d.claimed_count,
  d.pending_count,
  (d.load_snapshot -> 'queues' -> 'default' ->> 'latency')::float AS default_latency,
  (d.load_snapshot -> 'queues' -> 'push' ->> 'latency')::float AS push_latency,
  (d.load_snapshot -> 'queues' -> 'pull' ->> 'latency')::float AS pull_latency,
  (d.load_snapshot -> 'queues' -> 'push' ->> 'size')::int AS push_size,
  (d.execution_policy ->> 'execution_batch_size')::int AS execution_batch_size
FROM follow_import_dispatch_observations d
ORDER BY d.observed_at DESC;
```

### D. Delivery → Accept / Reject latency

```sql
SELECT
  t.destination_domain,
  t.state,
  EXTRACT(EPOCH FROM (t.completed_at - d.finished_at)) AS response_latency_seconds
FROM follow_import_targets t
JOIN LATERAL (
  SELECT o.finished_at
  FROM follow_import_transport_observations o
  WHERE o.target_id = t.id
    AND o.phase = 'activitypub_delivery'
    AND o.outcome = 'http_success'
  ORDER BY o.finished_at ASC
  LIMIT 1
) d ON TRUE
WHERE t.state IN ('accepted', 'rejected')
  AND t.completed_at IS NOT NULL;
```

Negative latency means Accept/Reject was recorded before the delivery
observation finished (the known race). Those rows are still valid; they
should not be treated as clock error alone.

## Known observation gaps

- Local follows that never hit `ActivityPub::DeliveryWorker`.
- Non-Follow-Import ActivityPub deliveries and relationship imports.
- Stoplight-open vs not-found during resolve (see above).
- Shared-inbox / alternate-host mapping is visible only as
  `destination_domain` ≠ `endpoint_origin`, not as a graph.
- Sidekiq retry index is not stored (only `sidekiq_job_id`).
- HTTP bodies, inbox paths, and remote error text are intentionally absent.
- No Node-level aggregation yet.
