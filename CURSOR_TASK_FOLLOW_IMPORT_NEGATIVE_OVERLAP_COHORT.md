# Cursor task: cohort backtest for Follow Import negative-target overlap

## Goal

Build the next analysis-only layer on top of PR #141.

PR #141 added:

`Moderation::FollowImportNegativeTargetOverlapService`

That service compares one Follow Import batch against historical moderation-action-linked `linked_negative_target_subject_ids`.

This task adds a **caller-supplied cohort aggregator/backtest** so we can run the overlap analysis over a selected set of real Follow Import batches and inspect distributions before designing any Cross-account Recurrence score or policy.

This remains strictly observational.

## Base / branch

Work on:

`analysis/follow-import-negative-overlap-cohort`

Base commit:

`f0e2c9365567be1d754f334f66afd629d200edbe`

(PR #141 merged)

## Required implementation

Add a read-only service, preferably:

`app/services/moderation/follow_import_negative_target_overlap_cohort_service.rb`

with an API along the lines of:

```ruby
Moderation::FollowImportNegativeTargetOverlapCohortService.new.call(batches)
```

The caller supplies the batch relation/enumerable.

Do **not** scan all FollowImportBatch rows internally by default.

Follow the design style of:

- `Moderation::MetricsDistributionService`
- `Moderation::FollowGateBacktestCohortService`

## Semantics

For each unique batch id:

1. call the existing `FollowImportNegativeTargetOverlapService`
2. preserve its no-look-ahead semantics (`as_of = batch.imported_at`)
3. summarize the factual overlap results
4. separate same-subject historical matches from cross-subject matches

Do not reimplement linked-negative matching logic independently.

## Per-batch row

Return a detailed row for every analyzed batch, including at minimum:

```text
batch_id
subject_id
imported_at
target_rows
comparable_unique_target_count
unresolved_or_unmapped_target_rows
candidate_snapshot_count
matching_snapshot_count

same_subject:
  matching_snapshot_count
  best_match

cross_subject:
  matching_snapshot_count
  best_match
```

A `best_match` should be selected deterministically using the existing service order (first matching row after its deterministic sort).

Expose useful fields from the best match, such as:

```text
snapshot_id
historical_subject_id
action_types
latest_action_performed_at
historical_fingerprint_complete
stored_linked_negative_target_count
reported_linked_negative_target_count
overlap_count
current_target_overlap_ratio
stored_negative_containment
jaccard
```

No labels like high/medium/low risk.

## Cohort summary

Return top-level factual summaries.

Suggested fields:

```text
generated_at
batch_count
subject_count
batches_with_any_overlap
batches_with_same_subject_overlap
batches_with_cross_subject_overlap
coverage
distributions
rows
elapsed_seconds
```

### Coverage

Include counts for historical best-match fingerprint completeness, separated where sensible:

- complete
- incomplete
- unknown

Do not convert unknown to complete/incomplete.

### Distributions

For both `same_subject` and `cross_subject`, summarize these best-match metrics across eligible batches:

- overlap_count
- current_target_overlap_ratio
- stored_negative_containment
- jaccard

Use raw observed values.

Report at least:

- n
- excluded_n
- nonzero
- min
- max
- mean
- percentiles

Use the same percentile set/style as `MetricsDistributionService` if practical:

`10, 25, 50, 75, 90, 95, 99`

A batch with no match in a category should be **excluded** from that category's best-match distribution, not inserted as an observed zero. The top-level overlap counts already show non-matches.

This avoids mixing "no historical evidence matched" with "a matched snapshot had metric zero" (the latter should not happen for overlap_count because match rows require >0).

## Same-subject vs cross-subject

These are descriptive categories only:

- same_subject = historical snapshot subject id equals current batch subject id
- cross_subject = different moderation subject id

Cross-subject overlap is **not identity proof**.

Do not call it account recreation, sockpuppet, same person, ban evasion, etc.

## No future outcome labels in this PR

Do not add "later suspended", "future moderation action", or similar outcome labels yet.

Reason: the first cohort export should be a clean measurement of the overlap feature itself. We can join known problematic / legitimate cohorts separately during calibration.

Do not leak future moderation actions into the feature rows.

## Read-only / no coupling

This PR MUST NOT modify:

- `Moderation::RiskEvaluationService`
- `Moderation::AdaptiveFollowGateDecisionService`
- `Moderation::ModeratorRecommendationService`
- Follow Import execution / dispatch / pacing
- evidence snapshot creation semantics
- moderation action recording
- Account / Follow / Block / Mute behavior

No DB migration.

No scoring.
No thresholds.
No recommendation.
No enforcement.

## Performance honesty

The underlying single-batch service currently scans eligible historical action-linked snapshots.

For this PR, do not silently add a complicated indexing redesign.

This cohort service is an **offline calibration tool for caller-selected cohorts**.

Expose `elapsed_seconds` so we can measure real production cost.

If you see an obvious N+1 that can be removed without changing semantics, fix it narrowly. Otherwise document the offline/small-cohort expectation rather than broadening scope.

## Tests

Add:

`spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb`

Cover at minimum:

1. de-duplicates repeated input batches by id
2. counts unique subjects correctly
3. batch with no overlap remains in rows but is excluded from same/cross distributions
4. separates same-subject and cross-subject matches
5. chooses deterministic best match using underlying match order
6. distribution math for overlap_count
7. distribution math for ratios
8. correct excluded_n
9. complete / incomplete / unknown fingerprint coverage counts
10. preserves no-look-ahead by relying on the underlying service with batch.imported_at
11. read-only: no changes to moderation/follow-import/relationship tables
12. empty cohort returns stable zero/empty shape

If useful, inject/double the single-batch overlap service in unit tests so the cohort aggregation logic is isolated, plus one integration-style example using real records to prove composition.

## Operator usage

Add a concise comment or documentation example showing how to run it from Rails console / rails runner with a caller-selected relation, e.g.:

```ruby
batches = FollowImportBatch.where(imported_at: 10.days.ago..Time.current).order(:imported_at)
result = Moderation::FollowImportNegativeTargetOverlapCohortService.new.call(batches)
puts JSON.pretty_generate(result)
```

Do not add a permanent rake task or CLI in this PR unless there is a compelling repository convention requiring it.

## Validation

Run at least:

```bash
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
bundle exec rubocop app/services/moderation/follow_import_negative_target_overlap_cohort_service.rb spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb
```

If touching any existing file, run its focused tests too.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add cohort analysis for Follow Import negative-target overlap`

PR body must explicitly say:

- read-only / analysis-only
- caller-supplied cohort; no implicit population scan
- composes PR #141 single-batch service
- same-subject and cross-subject overlap are separated
- cross-subject overlap is not identity inference
- no future moderation outcome labels
- no score/recommendation/gate/enforcement
- no DB migration
- no-look-ahead remains batch.imported_at
- reports elapsed time because this is an offline calibration path

## Final cleanup

This handoff file is temporary.

Before completion:

1. delete this file from the branch
2. ensure it is absent from final PR diff
3. leave only implementation/spec changes, unless a small persistent doc is genuinely needed

## Completion report

Return:

- Draft PR URL / number
- head SHA
- base SHA
- exact changed files
- result shape summary
- confirmation same vs cross are separated
- confirmation no future labels / no score / no gate / no enforcement
- confirmation no DB migration
- RSpec commands + exact results
- RuboCop command + exact result
- any performance observation / unresolved concern
