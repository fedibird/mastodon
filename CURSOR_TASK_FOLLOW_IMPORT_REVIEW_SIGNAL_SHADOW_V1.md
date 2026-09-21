# Cursor task: Follow Import review-signal shadow classifier v1

## Context

Merged foundations:

- #141-#145: linked-negative target overlap, cohort/campaign analysis, outcome backtest, recurrence diagnostics
- #147: durable Follow Import preflight barrier
- #148: generic Action Review policy/request foundation
- #149: Action Review admin queue/settings
- #150: first live Follow Import Action Review integration
  - `off` proceeds normally
  - `always` holds every Follow Import
  - `low/medium/high` are visible but currently receive signal=`none`
  - approve/stop is live
  - durable resume + CSV retention are live

Now add the first **automated review-signal classifier in SHADOW ONLY**.

This PR must NOT feed the classifier result into `ActionReview::PolicyDecisionService`.
The effective enforcement signal remains `none` in #150 semantics.

The goal is to collect causal, privacy-minimized, versioned production observations so we can calibrate before activating threshold policy modes.

## Branch / base

Work on:

`feature/follow-import-review-signal-shadow-v1`

Base:

`1a338baffaee24e00e3bb5c14ac8c23218a5f29f`

(#150 merged)

## Core safety rule

This PR must never change whether an import is held, approved, stopped, executed, paced, or resumed.

In particular:

- `off` stays normal
- `always` stays unconditional human review
- `high/medium/low` still behave as signal=`none` and therefore do NOT hold
- classifier errors do not block imports
- classifier latency does not sit on the synchronous preflight path

The classifier is observation only.

---

# Part A: pure versioned classifier

Add a pure service, suggested:

`FollowImport::ReviewSignalClassifier`

Result should contain at least:

- classifier_version
- signal_level: none / low / medium / high
- reason_codes
- normalized feature fields used by the classifier

Suggested version:

`follow-import-review-signal-shadow-v1`

Do not call this a risk score, abuse score, identity score, or probability.

## Input semantics

The classifier should consume the **cross-subject best match** from existing campaign recurrence semantics.

Use:

`Moderation::FollowImportRecurrenceObservationService`

as the feature source through a separate evaluator/adapter layer. Do not reimplement campaign grouping or overlap matching.

Only cross-subject linked-negative overlap can raise the v1 signal.

Same-subject overlap may be recorded as context/counts but must not raise the v1 signal.

Cross-subject recurrence is behavioral recurrence evidence, NOT identity proof.

## Conservative containment

Do NOT blindly use `stored_negative_containment` when the historical fingerprint was truncated.

Derive:

```text
conservative_negative_containment =
  overlap_count / max(stored_linked_negative_target_count,
                      reported_linked_negative_target_count)
```

when `reported_linked_negative_target_count` is valid and positive.

This behaves correctly for both:
- complete fingerprint: stored count is sufficient
- incomplete fingerprint: reported count is the larger/full denominator, so the ratio is a lower bound

When the reported count is missing/invalid, conservative containment is unknown/nil.

Never substitute stored count and pretend completeness is known.

## Provisional shadow thresholds

These are deliberately **candidate calibration thresholds**, not policy cutoffs.

Use constants and document them clearly:

```text
HIGH:
  overlap_count >= 100
  AND conservative_negative_containment >= 0.50

MEDIUM:
  overlap_count >= 25
  AND conservative_negative_containment >= 0.20

LOW:
  overlap_count >= 5
  AND conservative_negative_containment >= 0.05
```

Evaluate highest first.

If conservative containment is unknown:
- never emit medium/high
- emit low only when absolute overlap_count >= 10
- otherwise none

No cross-subject match -> none.

This intentionally allows some borderline low observations in shadow so we can measure false positives.

Production motivation only, NOT a guarantee:
- previously observed strong recurrence campaigns were around overlap 229-231 and containment ~0.645
- observed non-action controls were much lower; max observed containment was ~0.062 in the small calibration set
- sample size is tiny, so these thresholds MUST remain shadow-only

Do not encode any outcome/action result into the live classifier.

## Inputs that are context-only in v1

Record but DO NOT use to raise/lower v1 signal:

- current_target_overlap_ratio
- jaccard
- historical action_types
- latest historical action time
- migration_evidence
- account_age_seconds
- import mode
- same-subject overlap
- dispatch owner

Migration evidence may contextualize future policy but is not proof of legitimacy.

---

# Part B: causal shadow evaluator

Add a service, suggested:

`FollowImport::ReviewSignalShadowEvaluator`

Input: one `FollowImportBatch`.

It must call recurrence observation with:

- subject = batch.subject
- `now: batch.imported_at`
- default lookback 7 days
- default max_gap 30 minutes

The fixed `now=batch.imported_at` is critical.

It guarantees:
- later Follow Import batches are excluded
- later moderation actions are excluded by the existing comparator's as_of semantics
- future outcomes cannot leak into preflight features

The evaluator may run minutes/hours later; its feature cutoff remains the original import instant.

## Extracted context

Build a privacy-minimized observation payload.

Suggested successful payload shape:

```json
{
  "schema_version": 1,
  "classifier_version": "follow-import-review-signal-shadow-v1",
  "evaluation_status": "ok",
  "evaluated_at": "...actual wall clock...",
  "as_of": "...batch.imported_at...",
  "signal_level": "high",
  "reason_codes": ["cross_subject_overlap_high"],
  "features": {
    "campaign_batch_count": 1,
    "target_rows": 929,
    "comparable_unique_target_count": 929,
    "unresolved_or_unmapped_target_rows": 0,
    "cross_subject_matching_snapshot_count": 1,
    "overlap_count": 231,
    "current_target_overlap_ratio": 0.2486,
    "stored_negative_containment": 0.6507,
    "conservative_negative_containment": 0.6507,
    "jaccard": 0.0,
    "historical_fingerprint_complete": true,
    "stored_linked_negative_target_count": 355,
    "reported_linked_negative_target_count": 355,
    "historical_action_types": ["suspend"],
    "latest_historical_action_performed_at": "...",
    "same_subject_matching_snapshot_count": 0,
    "mode": "merge",
    "migration_evidence": "none",
    "account_age_seconds": 12345
  }
}
```

Numbers above are illustrative only.

Do NOT store in this shadow payload:

- raw account addresses
- target_key_hash values
- target subject IDs
- historical subject IDs
- snapshot IDs
- moderation action IDs
- post/profile text
- email/IP
- ActivityPub payloads
- identity labels

Historical action TYPES are allowed; IDs are not.

## Unavailable/no-match cases

Still return an `ok` shadow evaluation with signal none where possible.

Examples:

- recurrence observation unavailable because no prior comparable evidence
- no cross-subject match
- overlap below threshold

Use factual reason codes such as:

- `recurrence_observation_unavailable`
- `no_cross_subject_linked_negative_overlap`
- `cross_subject_overlap_below_shadow_threshold`
- `cross_subject_overlap_low_completeness_unknown`
- `cross_subject_overlap_low`
- `cross_subject_overlap_medium`
- `cross_subject_overlap_high`

If the evaluator itself raises, do not fabricate a signal.

---

# Part C: asynchronous shadow observer

Do NOT run campaign analysis synchronously inside the preflight DB lock.

Add:

`FollowImport::ReviewSignalShadowWorker`

Suggested behavior:

1. load batch by id
2. require operational cohort
3. if the v1 observation already exists, return
4. evaluate with fixed as_of=batch.imported_at
5. persist first successful observation
6. retry transient failures (small normal Sidekiq retry budget is fine)

Queue may be `pull` or `maintenance`; choose consistently with workload.

No execution state changes.

## Preflight hook

After `FollowImport::ActionReviewPreflightService` has completed the real #150 decision, best-effort enqueue the shadow worker.

Important:
- enqueue failure must be rescued/logged and must NOT change the preflight result
- do not run evaluator in the preflight transaction
- do not pass shadow signal into PolicyDecisionService
- for `always`, the ActionReviewRequest remains signal=`none`; do not silently add shadow evidence to the request

This separation is intentional so moderators are not influenced by an uncalibrated classifier.

---

# Part D: durable/backfill scheduler

An enqueue can be lost. Add a bounded periodic backstop:

`Scheduler::FollowImportReviewSignalShadowScheduler`

Suggested every 5 or 10 minutes.

Select:

- operational FollowImportBatch
- imported within the classifier lookback / a bounded recent window (7 days is fine)
- missing the v1 metadata key

Enqueue `ReviewSignalShadowWorker`.

Bound each pass, e.g. 500.

This also backfills recent pre-deploy operational batches for immediate calibration.

Do not touch historical dispatch cohort.

Do not change preflight_state.

Add to `config/sidekiq.yml`.

---

# Part E: safe metadata persistence

Use `FollowImportBatch.metadata`; no migration.

Add a dedicated key constant, suggested:

`REVIEW_SIGNAL_SHADOW_V1_KEY = 'review_signal_shadow_v1'`

Add public helpers such as:

- `review_signal_shadow_v1`
- `review_signal_shadow_v1_recorded?`
- `record_review_signal_shadow_v1!(payload)`

Persistence semantics:

- first successful observation wins for v1
- lock + reload + merge using the stale-write-safe metadata helpers added in #150
- must preserve completion, notification, and resume keys
- duplicate worker/scheduler runs are no-op after first success

Do not persist evaluator exception messages into metadata.

If useful, log only:
- batch id
- evaluator class/error class
- no raw target/account data

Future v2 should use a new metadata key, not overwrite v1.

---

# Part F: settings/UI wording only

Update Action Review settings hint for Follow Import.

It should now say approximately:

- `always` is live and holds every Follow Import
- `off` proceeds normally
- low/medium/high classifier runs in shadow for calibration
- low/medium/high do NOT yet affect whether an import is held

Do not display the per-batch shadow signal to moderators or users in this PR.

No queue badges/labels based on shadow classification.

---

# Part G: optional operator summary helper

If small and clean, add a read-only service or rake task that summarizes stored v1 observations without exposing IDs.

Preferred output:

- classifier_version
- generated_at
- lookback
- operational batch count
- observations present/missing
- signal counts none/low/medium/high
- reason_code counts
- evaluation coverage
- distributions by signal for:
  - overlap_count
  - conservative_negative_containment
  - current_target_overlap_ratio
  - comparable_unique_target_count
- fingerprint completeness counts
- migration_evidence counts by signal
- historical action_type counts by signal

No raw target list, account ids, subject ids, snapshot ids, or action ids.

This is optional; do not let it bloat the PR. If omitted, mention it in completion report and we will add/export separately.

---

# No enforcement activation

Explicitly DO NOT modify this #150 contract:

```ruby
ActionReview::PolicyDecisionService.new.call(
  operation_type: 'follow_import',
  signal_level: 'none',
  evaluation_status: 'ok'
)
```

The shadow classifier result must not be substituted here.

Do not implement:

- low/medium/high hold behavior
- automatic reject
- automatic account moderation
- RiskEvaluation changes
- AdaptiveFollowGate changes
- ModeratorRecommendation changes
- identity inference
- sockpuppet / ban-evasion claims
- outcome-driven live classification
- current/future post-campaign action leakage

---

# Tests

Add focused coverage for at least:

## Pure classifier

1. no cross-subject match -> none
2. overlap below low -> none
3. exact low boundary -> low
4. exact medium boundary -> medium
5. exact high boundary -> high
6. highest matching level wins
7. conservative containment uses max(stored, reported)
8. incomplete fingerprint can reach higher levels only through conservative lower-bound containment
9. missing reported count cannot emit medium/high
10. missing reported count + overlap >=10 may emit low
11. same-subject overlap alone -> none
12. action type does not change v1 level
13. migration evidence does not change v1 level
14. current-target ratio does not change v1 level

## Evaluator causality/privacy

15. recurrence service called with now=batch.imported_at
16. default lookback 7d / max_gap 30m
17. uses latest campaign observed-so-far
18. uses cross_subject best_match
19. strips snapshot_id
20. strips historical_subject_id
21. strips action_ids
22. no target ids/hashes/addresses in payload
23. retains action_types only
24. records completeness and conservative containment
25. unavailable recurrence -> factual none result

## Persistence

26. successful v1 observation stored in metadata
27. duplicate write keeps first v1 observation
28. stale metadata copy cannot delete completion/resume keys
29. future v2/other metadata key survives
30. evaluator exception is not persisted as fake success

## Worker

31. operational missing observation -> evaluate/store
32. existing observation -> no-op
33. historical cohort -> no-op
34. missing batch -> no-op
35. transient evaluator failure retries/raises according to worker contract without changing execution

## Scheduler

36. finds recent operational missing observations
37. ignores recorded observations
38. ignores historical cohort
39. ignores rows outside bounded window
40. pass is bounded

## Preflight shadow separation

41. classifier high + policy high STILL releases/no ActionReviewRequest because enforcement signal remains none
42. classifier high + policy medium STILL releases
43. classifier high + policy low STILL releases
44. policy always STILL holds regardless of classifier level
45. ActionReviewRequest created by always still has signal_level=none
46. request evidence does not contain shadow classifier payload
47. shadow enqueue failure does not block/reject/hold an otherwise-released import
48. shadow enqueue failure does not change unconditional always hold result
49. classifier is not called synchronously in preflight

## UI wording

50. Follow Import settings hint states shadow/non-enforcing threshold behavior
51. no user progress page includes signal level
52. Action Review queue/detail does not display v1 shadow level

## Regression

53. #150 Action Review integration specs remain green
54. metadata stale-writer specs remain green
55. preflight/release fencing remains green
56. no DB migration/schema change

---

# Validation

Run focused specs for:

- new classifier/evaluator/worker/scheduler
- FollowImportBatch
- ActionReviewPreflightService
- Action Review settings controller/form
- Action Review request/controller (to ensure shadow is not exposed)
- user import progress views/helpers
- #150 decision/resume specs

Run RuboCop on all changed Ruby/spec files.

Existing known baseline failures in old immediate ImportService specs may remain; clearly separate them in PR report if encountered.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add Follow Import review-signal shadow classifier`

PR body must explicitly state:

- SHADOW ONLY; no enforcement change
- Action Review still receives signal=none
- always remains the only automated policy mode that currently holds
- v1 uses only cross-subject action-linked linked-negative overlap
- thresholds are provisional calibration candidates
- exact low/medium/high thresholds
- conservative containment formula
- missing completeness caps signal as specified
- fixed as_of=batch.imported_at prevents future leakage
- worker + periodic backfill scheduler
- versioned privacy-minimized metadata snapshot
- no moderator/user exposure of shadow level
- no identity inference
- no DB migration
- exact RSpec/RuboCop results

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head/base SHA
- exact changed files
- classifier version
- exact thresholds
- conservative containment formula
- reason codes
- shadow metadata key/schema
- causality cutoff behavior
- worker + scheduler behavior
- proof enforcement signal remains none
- UI wording changes
- exact RSpec result
- exact RuboCop result
- whether optional operator summary was included
- any deviation / unresolved concern
