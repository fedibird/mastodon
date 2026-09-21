# Follow Import offline pacing backtest (I3)

Status: **analysis tooling only**. This document does not change runtime
Follow Import behaviour.

The backtest compares operator-supplied candidate pacing profiles against
**exported** transport / tick / dispatch-pass CSVs. It is the calibration
step after I2 (operational vs historical cohort) and before choosing
fixed/adaptive remote-pacing numbers or any GLOBAL canary.

It does **not**:

- enable `FOLLOW_IMPORT_DISPATCH_GLOBAL`
- enable remote-admission or adaptive enforcement
- change Sidekiq retries
- mutate Follow Import rows or Redis
- query live federation endpoints
- consume Accept/Reject, Follow Gate, blocks, reports, or other
  moderation signals
- invent production numeric defaults
- conclude that a global budget is safe for CPU or the database

Numeric values in scenario files are operator-owned and uncalibrated.
Do not copy a scenario from this document into production.

See also:

- `docs/follow_import_dispatch_pacing_design.md`
- `docs/follow_import_dispatch_shadow.md`
- `docs/follow_import_pacing_telemetry.md`

---

## Invocation

```bash
TRANSPORT=/path/to/transport.csv \
TICKS=/path/to/scheduler_ticks.csv \
DISPATCH=/path/to/dispatch_passes.csv \
SCENARIOS=/path/to/scenarios.json \
OUT_JSON=/tmp/follow-import-pacing-backtest.json \
OUT_MD=/tmp/follow-import-pacing-backtest.md \
bundle exec rake follow_import:pacing_backtest
```

`TRANSPORT` and `SCENARIOS` are required. `TICKS` and `DISPATCH` are
optional; when omitted, those sections are **unavailable**, not zero.
When those optional files are supplied, every parseable timestamp and
integer cell is read at load time. Malformed optional cells are counted
under prefixed keys such as `dispatch.observed_at` and
`ticks.planned_count`; they are never silently skipped or coerced to
`0`.

The task is read-only. Rails is loaded so the tool can reuse
`FollowImport::RemoteAdmissionProfile`,
`FollowImport::AdaptiveRemoteProfile`,
`FollowImport::AdaptiveRemoteCompatibility`,
`FollowImport::AdaptiveRemoteObservation`, and
`FollowImport::AdaptiveRemoteController`. The analysis itself executes
no SQL writes, no Redis writes, and no network.

Output schema:

- `schema`: `follow_import_pacing_backtest`
- `schema_version`: `1`
- scenario file `schema_version`: `1`

`generated_at` is the only non-deterministic field. Given the same CSVs
and scenario JSON, every analytical value is stable.

---

## Input contract

The tool depends on **column headers**, not operator filenames. Extra
columns are ignored. Missing required transport headers, a missing
required file, an invalid scenario/profile, zero usable
`activitypub_delivery` rows, or delivery rows that exist but none with a
usable event time (`request_started_at` else `started_at`) fail the
task with a non-zero exit. That last case is
`no usable timed activitypub_delivery rows`.

Malformed numeric or timestamp cells are counted in
`baseline.malformed_counts` and omitted from **only** the metric they
cannot support. They are never coerced to `0`.

### Transport (required)

Required core headers:

- `target_id`
- `phase`
- `started_at`
- `finished_at`
- `request_started_at`
- `request_finished_at`
- `enqueued_at`
- `queue_wait_ms`
- `request_duration_ms`
- `outcome`
- `http_status`
- `retry_after_seconds`
- `error_class`

Routing identity is selected **once per transport file** from headers.
Do not mix a raw destination with an anonymous origin. If both complete
sets are present, the task fails as ambiguous.

#### Raw mode

Headers:

```text
destination_domain
endpoint_origin
```

Backward compatible with #139. `destination_is_local` may be absent.
When absent, locality uses `TagManager#local_domain?` /
`web_domain?`. When present, the cell is an explicit hint (`t`/`f`,
`true`/`false`, `1`/`0`; case-insensitive words). An unknown value is
never coerced to false.

#### Anonymous mode (privacy export)

Headers:

```text
anon_destination_domain
anon_endpoint_origin
destination_is_local
```

Map them internally to the existing destination/origin identity fields.
Pseudonyms are opaque routing identities. Do not parse them as host
names. Never fall back to `TagManager`. Never require the raw
destination to accompany anonymous mode.

`destination_is_local` is required for every row whose anonymous
destination is nonblank. A blank destination may have blank locality
and remains the `UNKNOWN_DESTINATION` case. Missing or invalid
locality on a required row fails the task with a row/field error.

Accepted boolean cells:

```text
t / f
true / false
1 / 0
```

The selected mode is reported as
`baseline.dataset.routing_identity_mode` (`raw` or `anonymous`).

The SQL exporter itself is operator-side and is not in this repository.
The operator export should emit `destination_is_local` from the **raw**
destination before pseudonymization.

Only `phase=activitypub_delivery` enters delivery replay.
`resolve_account` and other phases remain in `row_count` only.

Two clocks are distinct:

- **Event time** (ordering, first-attempt ordinal, observation window):
  `request_started_at`, else `started_at`. `finished_at` is never the
  attempt origin.
- **Actual HTTP attempt**: `request_started_at` is present. A
  DeliveryWorker execution may have `started_at` without ever sending
  HTTP (Stoplight / DFT interruption). Those rows are timed executions,
  not HTTP attempts.

Attempt ordinal is reconstructed per `target_id` from timed delivery
rows by sorting event time then original CSV row number. Do not use a
target's current `delivery_attempts` field. Missing `target_id` stays
in aggregate transport counts and is excluded from target-level
first/retry metrics (`missing_target_id_count`).

### Scheduler ticks (optional)

Require `observed_at` when the file is supplied. Newer I2 columns
(`historical_pending_count`, `operational_pending_count`,
`planning_pending_count`, …) are summarized when present and reported
**unavailable** (not zero) when the export predates them.

Ticks are never mixed into the legacy dispatch-pass load envelope.

### Dispatch passes (optional)

Used only as a **historical load envelope** for
`BatchExecutionWorker` observations, not as an exact GLOBAL scheduler
replay. Require `observed_at`. `claimed_count` must be present to
compute the envelope.

---

## Scenario schema

```json
{
  "schema_version": 1,
  "bucket_seconds": 60,
  "scenarios": [
    {
      "name": "example-shape-only",
      "global_budget": 100,
      "fixed_profile": { "...": "RemoteAdmissionProfile v1 object" },
      "adaptive_profile": { "...": "AdaptiveRemoteProfile v1 object, optional" }
    }
  ]
}
```

The object under `fixed_profile` is parsed by
`FollowImport::RemoteAdmissionProfile`. When `adaptive_profile` is
present it is parsed by `FollowImport::AdaptiveRemoteProfile` and must
pass `FollowImport::AdaptiveRemoteCompatibility` against that fixed
baseline. Omit `adaptive_profile` for fixed-only analysis. Omit
`global_budget` to skip the load-envelope comparison for that scenario.

`bucket_seconds` is the **synthetic scheduler tick width** used to
group first-attempt / HTTP / claimed-count samples for
`per_tick_cap` and `global_budget`. It is not a wall-clock minute and
it is not a historical scheduler-tick boundary from the tick CSV.
Changing `bucket_seconds` changes how many samples fall in one bucket.
JSON reports `synthetic_tick_width_seconds` next to those views.

No scenario file with production recommendations is committed in this
repository. Synthetic specs may use arbitrary small numbers.

---

## First attempts vs retries

Remote admission caps govern **scheduler claims**. This tool
approximates them with **scheduler-originated first attempts** (ordinal
1 per `target_id` among timed delivery executions). That first-attempt
view is a claim-pressure proxy: it may include a first DeliveryWorker
execution that never reached HTTP.

Sidekiq retries appear as ordinal 2+ timed rows. The **all-attempt**
views count **actual HTTP requests** only (`request_started_at`
present). They are diagnostic transport pressure. They are not
re-paced by the dispatcher. A `circuit_or_stoplight_interruption` (or
any other pre-request interruption) with `started_at` and no
`request_started_at` is not an HTTP attempt and is not a suppression
in-window hit.

Always read both views. Do not treat all-attempt cap excess as a claim
budget miss.

---

## Fixed-cap pressure

This is a **pressure replay**, not an exact scheduler counterfactual.

For each scenario and each synthetic `bucket_seconds` tick, first-attempt
(timed executions, ordinal 1) and all-attempt (actual HTTP) rows are
counted per destination and per origin in deterministic input order. An
attempt is above a cap when it would be the (cap+1)th or later row for
that key in that bucket.

Routing matches production `RemoteAdmission`. Locality is the explicit
`destination_is_local` observation when supplied (required in anonymous
mode). Raw mode without that column still uses TagManager.

- a **local** destination consumes neither remote destination nor remote
  origin caps, and persists neither destination nor origin adaptive
  state
- a **missing** destination is pressure-counted in the synthetic
  `UNKNOWN_DESTINATION` bucket and is never treated as unlimited
- a missing destination does **not** apply origin pressure, even when
  the later transport row has `endpoint_origin`. Production cannot look
  up a destination→origin mapping without a destination key
- a missing destination is not persisted as an adaptive destination key.
  Observed origin may still persist adaptive controller state after an
  actual HTTP delivery
- a **remote** destination uses normal fixed/adaptive destination
  pressure. Origin pressure remains retrospective observed-origin
  pressure (I3 v1 limitation)

Destination pressure is directly observable from the imported routing
domain. Origin pressure is **retrospective observed-origin pressure**
from exported `endpoint_origin`. That is useful observationally, but it
is not an exact replay of PR F/G origin admission: production applies
the origin cap only when `RemoteRuntimeState` already has a fresh
destination→origin mapping at planning time. I3 v1 does not reconstruct
mapping-cache availability or TTL. `mapping_ttl_seconds` therefore does
not control whether a historical claim had an origin cap available.
`above_origin_cap` can overstate how often the live scheduler could
have applied the origin cap at claim time.

When destination and origin identities both exist, `above_either_cap`
counts the attempt once if it exceeds destination **or** origin.

`successful_above_either_cap` / `failed_above_either_cap` are
**constraint exposure**, not “this cap would have prevented N
failures” or “made N deliveries succeed”.

Attempts above cap stay in their historical bucket. The tool does not
reflow them into bucket N+1. That would fabricate a schedule the input
cannot support.

---

## Retry-After / recent-429 replay

Observed requests are replayed chronologically per `endpoint_origin`
using the same honour rules as `FollowImport::RemoteRuntimeState`:

- a usable `retry_after_seconds` becomes
  `min(requested, max_retry_after_seconds)`
- otherwise HTTP 429 uses `recent_429_cooldown_seconds`
- the stored honour deadline is `max(existing, proposed)`

Subsequent **observed HTTP** attempts whose event time falls inside that
hypothetical window are counted (`attempts_in_retry_after_window` /
`attempts_in_recent_429_window`), split first vs retry. Pre-request
DeliveryWorker executions are excluded.

This does **not** prove those requests would be absent in a live
system. It only records that their timestamps sit inside the candidate
suppression window. That view is useful when deciding later Retry-After
admission scope.

---

## Adaptive replay

The actual transport stream is replayed in memory through:

- `FollowImport::AdaptiveRemoteObservation.classify`
- `FollowImport::AdaptiveRemoteController.initial_view`
- `view_from_payload` (stale / digest reset)
- `AdaptiveRemoteController.apply`

No Redis. Destination and origin keys are independent. A local
destination skips both destination and origin remote layers, matching
production `RemoteAdmission`. A missing destination uses the unknown
bucket for destination pressure only, does not apply origin pressure,
and is not persisted as a destination key. Observed origin may still
persist origin controller state after an actual HTTP delivery. Latency,
Accept/Reject, blocks, reports, software type, user counts, and Follow
Gate are not inputs.

Neutral events (no request started, ordinary 4xx/3xx, unknown errors)
do not mutate cap state, matching `DeliveryObserver`. Persisted
controller state is updated **only** on a mutating apply. A stale /
digest reset from `view_from_payload` is counted as `stale_resets`
only when that reset is persisted as part of a mutating write. A
neutral event may observe a conservative cap for pressure; it does not
refresh stored `observed_at`.

Before each event is applied, the current adaptive cap is used for a
bucket-local pressure diagnostic (first-attempt timed executions and
all-attempt HTTP separately). Those counts are constraint exposure,
not causal prevention.

State summaries report cap distributions, min/max reached, failure vs
429 decreases, additive increases, persisted stale resets, and the
fraction of mutating events spent at `min_cap` or the fixed ceiling.

---

## Right censoring

The observation window is the min/max usable event timestamps in the
transport input.

For a target whose first attempt failed:

- a later success **in this same export** is
  `later_success_observed_within_window`
- otherwise `no_later_success_observed_within_window`

Never read the second case as a final failure probability. Accept and
Reject can arrive tens of hours later and are not transport pacing
inputs.

JSON and Markdown both include the window end and this warning.

---

## Global-budget load envelope

When dispatch-pass CSV is supplied **and** the scenario has
`global_budget`, the tool sums `claimed_count` into synthetic
`bucket_seconds` ticks and compares **active buckets**
(claimed_count > 0) with the candidate budget. Those ticks are not
wall-clock minutes.

Reported:

- `active_buckets`
- `claims_per_bucket` distribution (nearest-rank percentiles)
- `fraction_of_active_buckets_above_budget`
- sum of `max(observed_claims - candidate_budget, 0)`
- candidate budget / observed p50 and / observed peak
- `synthetic_tick_width_seconds`

There are no `active_minutes` / `claims_per_minute` fields. Excess is
not reflowed into later buckets. Clipped claims are not called a
“safe delay”.

CPU and database saturation are **not in the export**. The envelope
must not be used as a resource-safety verdict. There is no `cpu_safe`
/ `db_safe` field.

Scheduler ticks, when supplied, are summarized separately
(cadence, planned/claimed, budgets, pending including optional I2
cohort columns). Do not mix ticks and legacy dispatch passes.

---

## Percentiles

Method: `nearest_rank_ceil`.

For a sorted sample of length `n` and percent `p`:

- empty → unavailable (`count` is nil, never `0`)
- `p <= 0` → first value
- `p >= 100` → last value
- otherwise rank = `ceil(p/100 * n)` (1-indexed)

Rates and shares are rounded to 6 decimal places. Integer counts stay
integers.

---

## Privacy

Default JSON/Markdown must not emit raw destination domains, raw
endpoint origins, or raw anonymous identifiers. Detail tables hash
whatever identity the input supplied:

```text
input anon_destination_domain d0000972
-> output privacy label d_<sha256-12>
```

Blank keys are labelled `unknown` and are not hashed. Input file paths
in the result are basenames only.

Label stability:

- **raw** input: the same raw key produces the same output hash
- **anonymous** input: labels inherit the operator export's identity
  stability and are **not** guaranteed to be stable across separately
  generated exports

Do not treat anonymous `d_` / `o_` labels as cross-export destination
identity.

---

## Output

JSON is canonical. Top level:

- `schema` / `schema_version` / `generated_at`
- `input_files` (basenames)
- `observation_window`
- `warnings`
- `baseline`
- `scheduler_ticks`
- `scenarios[]`

Each scenario includes fixed profile identity/digest, optional adaptive
identity/digest, optional global budget, fixed-cap pressure,
suppression metrics, adaptive replay, load-envelope metrics, and
limitations.

Markdown is a short comparison table plus the same warnings. It does
not rank a winner, recommend a profile, or emit a score.

---

## Comparing multiple exports

Run the same scenario JSON against each export window and keep the JSON
beside that export. Compare:

- first-attempt vs all-attempt pressure (retries vs claims)
- destination/origin concentration shares (raw-mode privacy labels are
  stable for the same raw key; anonymous-mode labels are not
  cross-export stable)
- right-censored later-success counts (they grow if the window is
  longer)
- tick schema: older exports lack I2 columns
- dispatch-pass envelopes vs later GLOBAL ticks — never concatenate
  those series

Do not average incompatible windows into one “true” failure rate.

---

## Why Accept/Reject and moderation are excluded

Pacing is a transport/admission problem. Accept/Reject are follow
business outcomes and can lag by many hours. Follow Gate, blocks,
reports, and other moderation signals answer a different question and
must not drive AIMD or cap pressure. I3 therefore refuses those inputs
even when an operator export happens to include them as extra columns.
