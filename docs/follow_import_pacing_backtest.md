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
required file, an invalid scenario/profile, or zero usable
`activitypub_delivery` rows fail the task with a non-zero exit.

Malformed numeric or timestamp cells are counted in
`baseline.malformed_counts` and omitted from **only** the metric they
cannot support. They are never coerced to `0`.

### Transport (required)

Required headers:

- `target_id`
- `phase`
- `destination_domain`
- `endpoint_origin`
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

Only `phase=activitypub_delivery` enters HTTP-delivery replay.
`resolve_account` and other phases remain in `row_count` only.

Event time for an HTTP attempt:

1. `request_started_at`
2. else `started_at`

`finished_at` is never the attempt origin.

Attempt ordinal is reconstructed per `target_id` by sorting event time
then original CSV row number. Do not use a target's current
`delivery_attempts` field. Missing `target_id` stays in aggregate
transport counts and is excluded from target-level first/retry metrics
(`missing_target_id_count`).

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

No scenario file with production recommendations is committed in this
repository. Synthetic specs may use arbitrary small numbers.

---

## First attempts vs retries

Remote admission caps govern **scheduler claims**, which this tool
approximates with **scheduler-originated first attempts** (ordinal 1
per `target_id` in the export).

Sidekiq retries appear as ordinal 2+ transport rows. They are reported
in the **all-attempt** views as diagnostic transport pressure. They
are not re-paced by the dispatcher.

Always read both views. Do not treat all-attempt cap excess as a claim
budget miss.

---

## Fixed-cap pressure

This is a **pressure replay**, not an exact scheduler counterfactual.

For each scenario and each `bucket_seconds` bucket, first-attempt and
all-attempt rows are counted per destination and per origin in
deterministic input order. An attempt is above a cap when it would be
the (cap+1)th or later row for that key in that bucket.

When both destination and origin are known, `above_either_cap` counts
the attempt once if it exceeds destination **or** origin.

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

Subsequent **observed** attempts whose event time falls inside that
hypothetical window are counted (`attempts_in_retry_after_window` /
`attempts_in_recent_429_window`), split first vs retry.

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

No Redis. Destination and origin keys are independent. Local
destinations are skipped on the destination layer, matching production
`AdaptiveRemoteState`. Latency, Accept/Reject, blocks, reports,
software type, user counts, and Follow Gate are not inputs.

Neutral events (no request started, ordinary 4xx/3xx, unknown errors)
do not mutate cap state, matching production.

Before each event is applied, the current adaptive cap is used for a
bucket-local pressure diagnostic (first-attempt and all-attempt
separately). Those counts are constraint exposure, not causal
prevention.

State summaries report cap distributions, min/max reached, failure vs
429 decreases, additive increases, stale resets, and the fraction of
mutating events spent at `min_cap` or the fixed ceiling.

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
`global_budget`, the tool sums `claimed_count` into `bucket_seconds`
minutes and compares **active** minutes (claimed_count > 0) with the
candidate budget.

Reported:

- active minutes
- claims/min distribution (nearest-rank percentiles)
- fraction of active minutes above the candidate budget
- sum of `max(observed_claims - candidate_budget, 0)`
- candidate budget / observed p50 and / observed peak

Excess is not reflowed into later minutes. Clipped claims are not
called a “safe delay”.

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

Default JSON/Markdown must not emit raw destination domains or endpoint
origins. Detail tables use `d_<sha256-12>` / `o_<sha256-12>`. Blank
keys are labelled `unknown` and are not hashed.

Input file paths in the result are basenames only.

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
- destination/origin concentration shares (privacy labels are stable
  for the same raw key)
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
