# Cursor task: I3 Follow Import offline pacing backtest and profile calibration tooling

> **TEMPORARY IMPLEMENTATION INSTRUCTION**
>
> Read this document first. Create a new implementation branch from the latest
> `fedibird`, implement the task, run the required tests, open a Draft PR, and
> **delete this file from the implementation branch before finishing**.
>
> The finished PR must not retain this temporary instruction document.

## Goal

Implement I3 from the Follow Import rollout:

> Build a reproducible, read-only, offline backtest/calibration tool that compares
> candidate Follow Import pacing profiles against exported production telemetry.

This PR is **analysis tooling only**.

It must not:

- enable `FOLLOW_IMPORT_DISPATCH_GLOBAL`
- enable remote-admission enforcement
- enable adaptive enforcement
- change runtime pacing behavior
- add production numeric defaults
- change Sidekiq retry behavior
- mutate Follow Import rows
- mutate Redis
- query live federation endpoints
- use moderation / Follow Gate signals

The purpose is to make the next production profile decision evidence-based and
repeatable.

---

## Current rollout state

The relevant production sequence is now:

1. #137 fixed the PgBouncer/session-advisory-lock problem with a durable row +
   transaction-scoped serialization/fencing.
2. Production verification after #137 showed the legacy stranded advisory lock
   at zero rows and healthy shadow cadence.
3. #138 / I2 separated historical pre-controlled-execution pending rows from the
   operational dispatch cohort.
4. GLOBAL remains OFF.

I3 is therefore **not** another runtime change. It is the offline calibration step
before choosing fixed/adaptive remote-pacing parameters and before any GLOBAL
canary.

---

## Known production observations to preserve as context, not hard-coded conclusions

The existing operator exports have shown approximately:

- legacy controlled-dispatch active minutes around ~333 claims/min average and
  peaks around ~500/min during the short observed dispatch window
- transport delivery peaks around ~628/min
- first HTTP queue wait was generally small (historically p99 < ~0.7s in the
  observed window), so the push queue did not look like the immediate bottleneck
- remote account resolution was much slower than the push enqueue path
- failure/retry traffic is highly concentrated in a minority of
  destinations/origins
- retry amplification is large; many failed targets reached repeated attempts
- observed later HTTP success after a retry was uncommon in the short telemetry
  window, but this is **right-censored** and must never be reported as a final
  failure probability
- some healthy high-volume destinations sustained materially more than 50
  first attempts/min with very high success
- a global budget of 50/min is far below historically observed active dispatch
  throughput
- CPU and database saturation metrics are not present in the exported pacing
  dataset, so the tooling must **not** conclude that a particular global budget
  (for example 300/min) is safe for CPU/DB
- Accept/Reject business responses can arrive tens of hours later and are not
  transport pacing inputs

These observations motivate the analysis dimensions. They are not production
defaults and must not be encoded as profile recommendations.

---

## Core epistemic rule

The production telemetry is observational.

Do not report:

- “this cap would have prevented N failures”
- “this profile would have made N deliveries succeed”
- “this global budget is safe”
- “retry success probability is X%”
- “destination X is bad because users rejected follows”

The tool may report:

- observed request/first-attempt pressure above a hypothetical cap
- observed successful requests that were also above that cap
- observed failure requests that were above that cap
- observed attempts that occurred inside a hypothetical Retry-After/recent-429
  suppression window
- controller state/cap trajectories when replaying observed transport events
- relative clipping against historical dispatch/load envelopes
- failure concentration and retry amplification
- right-censored “later success observed within this export window”

Always distinguish:
- **scheduler-originated first-attempt pressure**
- **all HTTP attempts including Sidekiq retries**

Remote admission caps govern scheduler claims, not generic retry traffic.

---

## Input model

The tool operates on exported CSV files. It must not require production DB access.

Provide a Rake/CLI entry point with explicit file arguments. Preferred:

```bash
TRANSPORT=/path/to/transport.csv \
TICKS=/path/to/scheduler_ticks.csv \
DISPATCH=/path/to/dispatch_passes.csv \
SCENARIOS=/path/to/scenarios.json \
OUT_JSON=/tmp/follow-import-pacing-backtest.json \
OUT_MD=/tmp/follow-import-pacing-backtest.md \
bundle exec rake follow_import:pacing_backtest
```

`TRANSPORT` and `SCENARIOS` are required.

`TICKS` and `DISPATCH` are optional; when absent, corresponding sections are
reported as unavailable rather than zero.

Do not depend on a particular operator export filename. Depend on required column
headers and give a clear error when required columns are absent.

### Transport columns

Support at least the current Follow Import transport export semantics:

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

Extra columns must be ignored safely.

Only `phase=activitypub_delivery` belongs in the HTTP-delivery replay.

### Scheduler tick columns (optional)

Consume the exported fields needed for:

- `observed_at`
- `scheduler_mode`
- `outcome`
- `planned_count`
- `claimed_count`
- `global_base_budget`
- `effective_global_budget`
- `global_pending_count`
- `historical_pending_count`
- `operational_pending_count`
- `planning_pending_count`
- relevant load snapshot / execution-config data when exported

Do not require every historical schema version to contain I2 columns. Missing
newer columns should be reported as unavailable for older rows.

### Dispatch-pass columns (optional)

Use legacy controlled-dispatch observations only as a **historical load envelope**,
not as an exact GLOBAL scheduler replay.

Consume at least:

- `observed_at`
- `candidate_count`
- `claimed_count`
- `global_pending_count`
- `active_batch_count`
- local-load observation fields if present

---

## Scenario file

Use an explicit JSON scenario file. Do not bundle production numeric defaults.

Suggested schema:

```json
{
  "schema_version": 1,
  "bucket_seconds": 60,
  "scenarios": [
    {
      "name": "candidate-a",
      "global_budget": 100,
      "fixed_profile": {
        "version": 1,
        "destination": { "per_tick_cap": 20 },
        "origin": { "per_tick_cap": 20 },
        "runtime": {
          "mapping_ttl_seconds": 3600,
          "max_retry_after_seconds": 3600,
          "recent_429_cooldown_seconds": 300
        },
        "scan": {
          "max_targets_per_batch": 100,
          "max_windows_per_batch": 20
        }
      },
      "adaptive_profile": {
        "version": 1,
        "destination": {
          "initial_cap": 10,
          "min_cap": 1,
          "additive_step": 1,
          "successes_per_increase": 20,
          "failure_multiplier_percent": 70,
          "rate_limit_multiplier_percent": 50
        },
        "origin": {
          "initial_cap": 10,
          "min_cap": 1,
          "additive_step": 1,
          "successes_per_increase": 20,
          "failure_multiplier_percent": 70,
          "rate_limit_multiplier_percent": 50
        },
        "runtime": {
          "stale_after_seconds": 3600,
          "state_ttl_seconds": 86400
        }
      }
    }
  ]
}
```

**The numbers above are shape-only examples for this task document. Do not copy
them into a committed production scenario or describe them as recommendations.**

The implementation should validate candidate profiles through the existing
production parsers:

- `FollowImport::RemoteAdmissionProfile`
- `FollowImport::AdaptiveRemoteProfile`
- `FollowImport::AdaptiveRemoteCompatibility`

If an adaptive profile is omitted, run fixed-only analysis.

If `global_budget` is omitted, omit the global-load-envelope comparison for that
scenario.

No scenario file with actual production recommendations should be committed.

Synthetic test fixtures may contain arbitrary small numbers.

---

## Normalization and attempt identity

### Event time

For an actual HTTP attempt, use:

1. `request_started_at`
2. else `started_at`

Do not use `finished_at` as the attempt origin.

Rows with no request-start evidence may still contribute to baseline outcome
counts, but they are neutral for adaptive mutation exactly as
`AdaptiveRemoteObservation` defines.

### Attempt ordinal

Do **not** trust a target's current `delivery_attempts` field or any final target
state as the historical attempt ordinal.

For each `target_id`, sort its transport rows by event time plus a stable
input-row tie breaker and derive:

- attempt 1 = first observed delivery row for that target
- attempt 2+ = observed retries

If target_id is missing, keep the row in aggregate transport counts but exclude it
from target-level first/retry metrics and report that exclusion count.

### Right censoring

Let the observation window be bounded by the min/max usable event timestamps in
the input.

For a target whose first attempt failed:

- later success in this same export may be reported as
  `later_success_observed_within_window`
- no later success must be reported as
  `no_later_success_observed_within_window`

Never call the second case “final failure”.

Include the observation-window end and right-censoring warning in JSON and
Markdown outputs.

---

## Baseline analysis

Produce at least these aggregate sections.

### 1. Dataset/window

- row count
- usable activitypub_delivery rows
- rows with request timestamps
- rows with/missing target_id
- min/max event time
- duration
- destination count
- origin count

### 2. First attempts

- unique target count with attempt identity
- first-attempt outcome/status distribution
- first-attempt success count/rate
- first-attempt retryable/timeout/connection/unknown/unsalvageable counts
- per-minute (or scenario bucket) total first-attempt distribution:
  min/p50/p90/p95/p99/max

### 3. Retry amplification

- targets with attempts >=2
- total retry rows
- attempt-count distribution per target
- max observed attempt count
- later success observed within window
- no later success observed within window
- explicit right-censoring note

### 4. Concentration

For destination and origin separately:

- total actual request attempts
- first attempts
- success / 429 / 5xx / timeout / connection failure counts
- concentration shares for top 1 / top 5 / top 10 keys for:
  - attempts
  - connection failures
  - timeouts
  - 5xx
  - 429

Default output should not reveal raw domains/origins.

Use a deterministic privacy-safe label for detail tables, e.g.
`d_<sha256-prefix>` / `o_<sha256-prefix>`.

Do not hash blank/missing values into a misleading real key; label them
`unknown`.

### 5. Latency / queue wait

Report distributions for observed:

- first-attempt queue_wait_ms
- first-attempt request_duration_ms
- all-attempt request_duration_ms

Do not use request latency as an adaptive controller input.

---

## Fixed-cap scenario replay

This is a **pressure replay**, not an exact scheduler counterfactual.

For each scenario and fixed-width time bucket:

### First-attempt view

For each destination:

- observed first attempts in bucket
- count within destination cap
- count above destination cap

For each known origin:

- same against origin cap

When both destination and origin are known, compute the number that would exceed
either fixed ceiling under deterministic input order.

Report:

- total observed first attempts
- first attempts above destination cap
- first attempts above origin cap
- first attempts above either cap
- successful first attempts above either cap
- failed first attempts above either cap

The last two are **constraint exposure**, not prevented successes/failures.

### All-attempt view

Run the same pressure math over all actual HTTP attempts and report it separately
as transport pressure.

Explicitly state:

> all-attempt cap excess is diagnostic transport pressure; scheduler claim caps do
> not directly pace Sidekiq retries.

### No deferred reflow

Do not take an attempt above cap in bucket N and move it into bucket N+1.

That would create a fabricated counterfactual schedule and cascading state that
the input cannot support.

Count it as `observed_above_cap` and leave the historical timestamp unchanged.

---

## Retry-After / recent-429 replay

Using each scenario's fixed profile:

Replay observed request events chronologically per endpoint origin.

Match current production semantics from `RemoteRuntimeState`:

- a usable `retry_after_seconds` creates
  `min(requested, max_retry_after_seconds)`
- otherwise HTTP 429 creates `recent_429_cooldown_seconds`
- suppression is max(existing honor_until, proposed honor_until)

Report subsequent **observed** request attempts that occurred while that
hypothetical suppression was active:

- attempts_in_retry_after_window
- attempts_in_recent_429_window
- unique targets represented
- first-attempt vs retry split

Do not say those requests “would definitely not occur” in a full system
counterfactual. Say they are requests whose observed timestamps fall inside the
candidate suppression window.

This section is particularly useful for deciding I4 scope later.

---

## Adaptive replay

Replay the actual transport event stream through the existing pure controller
semantics.

Reuse, do not reimplement:

- `FollowImport::AdaptiveRemoteObservation.classify`
- `FollowImport::AdaptiveRemoteController.initial_view`
- `view_from_payload` or equivalent pure state semantics
- `AdaptiveRemoteController.apply`

No Redis.

Maintain in-memory state independently for:

- destination_domain
- endpoint_origin

Respect:

- fixed cap as ceiling
- initial_cap
- min_cap
- additive recovery
- success credit
- failure multiplier
- stronger 429 multiplier
- stale reset
- neutral events

Do not make latency, Accept/Reject, blocks, reports, software type, user count,
or Follow Gate inputs.

### Adaptive pressure metric

Before applying each observed event's feedback, use the current adaptive cap for
that destination/origin to compute a bucket-local cap-pressure diagnostic.

Report separately for first attempts and all attempts:

- observed rows above current destination adaptive cap
- observed rows above current origin adaptive cap
- observed rows above either adaptive cap
- successful rows above adaptive cap
- failed rows above adaptive cap

Again: these are constraint-exposure metrics, not causal prevention estimates.

### State summary

For destination and origin layers:

- number of keys observed
- cap-before / cap-after distribution
- minimum reached
- maximum reached
- count of decreases due failure
- count of stronger decreases due 429
- count of additive increases
- count of stale resets
- fraction of mutating events spent at min_cap
- fraction at fixed ceiling
- success-credit distribution if useful

Keep output aggregate/privacy-safe by default.

---

## Global-budget envelope

If legacy dispatch-pass data is supplied and the scenario has `global_budget`,
compute a clearly-labelled **historical load-envelope comparison**.

Examples:

- active minutes observed
- claims/min distribution
- fraction of active minutes above candidate budget
- sum of `max(observed_claims - candidate_budget, 0)`
- p50/p90/p95/p99/max observed claims/min
- candidate budget / observed p50 and candidate budget / observed peak ratios

Do not reflow excess claims into future minutes.

Do not call clipped claims “safe delay”.

Do not infer CPU/DB safety because those resources are not measured by the export.

If scheduler tick data is supplied, summarize the newer scheduler cadence and
planned/claimed budgets separately, preserving schema/cohort distinctions. Do not
mix legacy dispatch passes and GLOBAL scheduler ticks into one series.

---

## Scenario comparison output

JSON must be the canonical machine-readable result.

Include:

```text
schema
schema_version
generated_at
input_files (basename only)
observation_window
warnings
baseline
scenarios[]
```

Each scenario should include:

- scenario name
- fixed profile identity/digest
- adaptive profile identity/digest if any
- global budget if any
- fixed-cap pressure metrics
- suppression-window metrics
- adaptive replay metrics
- global-budget envelope metrics if available
- limitations/warnings

Also produce a concise Markdown report suitable for attaching to a GitHub review
or saving beside an observation export.

The Markdown should make candidate comparison easy but must **not rank a winner**.
Use a neutral table per scenario such as:

```text
Scenario | First attempts above fixed caps | Successful first attempts above caps |
429/Retry-After window attempts | Adaptive min-cap exposure | Legacy minutes above global budget
```

Do not emit “best”, “recommended”, “winner”, or a score.

---

## Determinism

Given the same CSVs and scenario JSON, all analytical values must be deterministic
except `generated_at`.

Stable-sort ties by original CSV row number.

JSON ordering should be stable where practical.

Percentile implementation must be documented and tested.

Floating output should use a consistent precision.

---

## Failure handling

Fail with a clear non-zero task error for:

- missing required input file
- invalid scenario schema
- invalid fixed profile
- incompatible adaptive profile
- missing required transport headers
- no usable activitypub_delivery rows

Optional missing TICKS/DISPATCH files are not errors if not supplied.

Malformed individual numeric/time cells should be counted and skipped from only
the metric they cannot support; report malformed-row counts. Do not turn malformed
data into zero.

---

## Implementation shape

Use repository-native Ruby and existing FollowImport classes.

A reasonable structure is:

```text
app/services/follow_import/pacing_backtest/
  input.rb
  scenario.rb
  analyzer.rb
  fixed_pressure_replay.rb
  suppression_replay.rb
  adaptive_replay.rb
  report.rb

lib/tasks/follow_import.rake
docs/follow_import_pacing_backtest.md
```

Equivalent decomposition is fine.

Do not add gems unless absolutely necessary. Ruby CSV/JSON/Digest should be
enough.

Keep pure replay classes independent from Rails DB.

The Rake task may load Rails to reuse existing profile/controller classes, but
the analysis itself must execute no SQL writes, no Redis writes, and no network.

---

## Tests

Use synthetic fixtures only. Do not commit production export data.

At minimum test:

### Input / attempt reconstruction

1. filters activitypub_delivery correctly
2. event-time preference is request_started_at then started_at
3. derives attempt ordinals per target
4. stable tie breaking
5. missing target ids excluded only from target-level metrics
6. right-censored wording/data semantics
7. malformed cells reported, not coerced to zero

### Fixed pressure replay

8. destination cap excess
9. origin cap excess
10. either-cap excess without double counting
11. successful vs failed constrained rows
12. first-attempt and all-attempt views differ when retries exist
13. no deferred reflow

### Suppression replay

14. Retry-After delta is capped by profile max
15. repeated suppression keeps the later honor_until
16. 429 without Retry-After uses recent-429 cooldown
17. attempts inside windows split first/retry correctly

### Adaptive replay

18. classification uses production AdaptiveRemoteObservation
19. success additive recovery
20. generic failure multiplicative decrease
21. 429 stronger decrease
22. neutral events do not mutate state
23. stale reset
24. fixed ceiling respected
25. destination and origin independent
26. first-attempt adaptive pressure separated from all attempts

### Global envelope

27. missing dispatch input -> unavailable, not zero
28. claims/min distribution
29. candidate-budget excess without reflow
30. no CPU/DB safety conclusion field exists

### Reporting

31. JSON deterministic aside from generated_at
32. Markdown contains right-censoring/causality warning
33. Markdown does not contain winner/recommended/best scoring language
34. raw domains/origins absent from default output

Add task-level tests if practical.

---

## Tests to run

Run the new backtest specs plus relevant production-controller/profile specs:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/services/follow_import/pacing_backtest \
  spec/services/follow_import/remote_admission_profile_spec.rb \
  spec/services/follow_import/adaptive_remote_profile_spec.rb \
  spec/services/follow_import/adaptive_remote_compatibility_spec.rb \
  spec/services/follow_import/adaptive_remote_controller_spec.rb \
  spec/services/follow_import/adaptive_remote_observation_spec.rb
```

If specs are placed in different paths, adjust accordingly.

Run RuboCop on all changed Ruby/Rake files.

Report exact example/failure counts.

---

## Permanent documentation

Add `docs/follow_import_pacing_backtest.md` and link it from the existing pacing
docs where appropriate.

Document:

- input contract
- scenario schema
- invocation
- output fields
- first-attempt vs retry distinction
- fixed-cap pressure semantics
- adaptive event semantics
- suppression replay semantics
- right censoring
- causal limitations
- global-budget load-envelope limitation
- why CPU/DB safety is not inferred
- why Accept/Reject and moderation data are excluded
- how to compare multiple exports over time

Do not commit a production profile recommendation in this PR.

---

## PR body

Open one focused Draft PR against `fedibird`.

The PR body must include:

1. why I3 is analysis-only
2. data inputs and privacy behavior
3. fixed-cap pressure methodology
4. Retry-After/429 replay methodology
5. adaptive replay methodology
6. right-censoring limitations
7. global-budget envelope limitations
8. test results
9. example command using synthetic/example paths only
10. confirmation no runtime feature flags/defaults changed
11. confirmation no production telemetry data is committed

---

## Mandatory cleanup

Before declaring the task complete:

1. commit code/spec/permanent-doc changes
2. **delete `docs/CURSOR_TASK_follow_import_pacing_backtest.md`**
3. commit that deletion
4. open/update the Draft PR
5. report:
   - PR URL
   - head SHA
   - changed files
   - task/CLI invocation
   - scenario schema version
   - output schema version
   - test counts
   - RuboCop result
   - confirmation the temporary task file is absent from PR HEAD

The temporary instruction is only the handoff artifact.
