# Cursor task: campaign-level Follow Import negative-target overlap

## Why this PR

Production cohort analysis from PR #142 showed that batch-level overlap is useful but can fragment one subject's apparent recurrence across many closely spaced Follow Import batches.

Observed examples from the 2026-09-21 production export:

- subject 16451: three batches within ~90s; one batch overlapped historical subject 13133's linked-negative fingerprint by 200 targets, another by 18, another by 78
- subject 18158: two batches within ~1s; overlap 200 and 78 against historical 13133
- subject 26453: fourteen batches across ~27 minutes; individual best overlaps ranged from 4 to 84, against historical subjects 13133 / 18158
- subject 19051: three batches at the same timestamp with the same best-match metrics

This means batch-level best-match distributions can understate or duplicate campaign-level recurrence.

The next step is **campaign aggregation**, still analysis-only. Do not introduce scoring or policy.

## Base / branch

Work on:

`analysis/follow-import-campaign-negative-overlap`

Base commit:

`3a49eddd6ec6e1a18e99b3f5626da08a8d24d391`

(PR #142 merged)

## Goal

Add a read-only service that:

1. groups caller-supplied FollowImportBatch rows into temporal campaigns per moderation subject
2. unions comparable resolved target_subject_ids across each campaign
3. compares that union against historical action-attached linked-negative fingerprints
4. preserves strict no-look-ahead semantics
5. reports same-subject vs cross-subject matches
6. remains a calibration tool only

## Campaign grouping

Prefer a service such as:

`Moderation::FollowImportCampaignNegativeTargetOverlapService`

API may be:

```ruby
service.call(batches, max_gap: 30.minutes)
```

Requirements:

- caller supplies batches; never default to all batches
- sort by `subject_id, imported_at, id`
- same subject only
- start a new campaign when the gap between consecutive batches exceeds `max_gap`
- `max_gap` must be explicit in result metadata
- default 30.minutes is acceptable for analysis because it captures the observed 26453 sequence, but document that this is a **grouping heuristic, not a risk threshold**
- make max_gap injectable so calibration can compare 5m/15m/30m/60m later
- de-duplicate repeated input batch ids

Do not use account identity beyond ModerationSubject id.

## Campaign time semantics / no future leakage

For each campaign:

- `started_at` = earliest batch.imported_at
- `ended_at` = latest batch.imported_at
- historical moderation evidence eligible for comparison must satisfy:
  `ModerationAction.performed_at <= campaign.started_at`

Freeze the historical baseline at campaign start.

This is important: a moderator action created during the campaign must not retroactively become historical evidence for that same campaign.

The campaign can include targets from later batches in the campaign because this is an offline completed-campaign analysis. Make this distinction explicit.

## Current campaign target set

Union unique non-NULL `FollowImportTarget#target_subject_id` across all campaign batches.

Also report:

- batch_count
- batch_ids
- import_ids (non-NULL; factual metadata)
- raw target row total
- comparable unique resolved target count
- unresolved/unmapped row total
- first/last imported_at
- campaign duration seconds
- mode counts if easy
- migration_evidence counts if easy

Do not use target_key_hash as identity for overlap.

Do not double-count the same target appearing in multiple batches.

## Historical comparison

Use the exact same historical semantics as PR #141:

- only ModerationEvidenceSnapshot rows linked to >=1 ModerationAction
- only linked_negative_target_subject_ids
- correlated_negative_target_subject_ids excluded
- no general contacted target sets
- no full historical import target similarity

Avoid duplicating the core overlap math if practical.

A small refactor of PR #141's service is allowed if it cleanly extracts a reusable target-set comparison core while keeping existing public behavior/specs unchanged.

Preferred architecture:

- existing FollowImportNegativeTargetOverlapService remains the single-batch adapter
- extract a reusable read-only comparator that accepts:
  - current subject id
  - current comparable target ids
  - target row/unresolved counts
  - as_of
  - analysis id/type metadata
- campaign service composes that comparator

Do not broaden into scoring.

## Result shape

Top-level:

```text
generated_at
max_gap_seconds
campaign_count
subject_count
campaigns_with_any_overlap
campaigns_with_same_subject_overlap
campaigns_with_cross_subject_overlap
coverage
distributions
campaigns
elapsed_seconds
```

Per campaign:

```text
campaign_index or stable derived identifier
subject_id
started_at
ended_at
duration_seconds
batch_count
batch_ids
import_ids
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

Best-match fields should mirror #141/#142:
snapshot_id, historical_subject_id, action types/time, fingerprint completeness, stored/reported negative counts, overlap_count, current_target_overlap_ratio, stored_negative_containment, jaccard.

## Distributions

Same style as PR #142, but campaign-level.

For same_subject and cross_subject best matches:

- overlap_count
- current_target_overlap_ratio
- stored_negative_containment
- jaccard

Report:
n, excluded_n, nonzero, min, max, mean, p10/p25/p50/p75/p90/p95/p99.

No-match campaigns are excluded from match distributions, not inserted as zero.

## Important guardrails

- campaign grouping != evidence of abuse
- cross-subject overlap != same person
- no account recreation / ban evasion labels
- no score
- no "high overlap" label
- no threshold-to-action mapping
- no RiskEvaluation change
- no AdaptiveFollowGate change
- no ModeratorRecommendation change
- no enforcement
- no DB migration
- no writes

## Tests

Add focused specs covering at least:

1. same subject batches inside max_gap group into one campaign
2. same subject gap > max_gap starts a new campaign
3. different subjects never group
4. repeated input batch id de-duplicates
5. target union de-duplicates targets across batches
6. unresolved rows are counted but excluded from comparable target union
7. historical cutoff uses campaign.started_at
8. action created between campaign start and later batch is excluded
9. same/cross separation
10. fingerprint complete/incomplete/unknown preserved
11. campaign-level overlap math uses union, not sum of per-batch overlaps
12. no-match campaigns excluded from distributions
13. empty cohort stable shape
14. read-only guarantees
15. existing #141 and #142 specs stay green

Include a regression example modeled after the production fragmentation shape:
- multiple closely spaced batches for one subject
- overlapping target subsets across batches
- verify campaign union creates one deduplicated comparable set and one factual overlap result

## Validation

Run at least:

```bash
bundle exec rspec spec/services/moderation/follow_import_campaign_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb
bundle exec rubocop app/services/moderation/follow_import_campaign_negative_target_overlap_service.rb spec/services/moderation/follow_import_campaign_negative_target_overlap_service_spec.rb
```

If you extract a reusable comparator, run focused specs for every changed file.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add campaign-level Follow Import negative-target overlap analysis`

PR body must state:

- motivated by production batch fragmentation observed after #142
- grouping is caller-supplied + configurable temporal heuristic
- default max_gap is analysis grouping only, not policy threshold
- historical baseline freezes at campaign started_at
- campaign target union is de-duplicated
- same/cross separated
- no identity inference
- no score/recommendation/gate/enforcement
- no migration
- read-only

## Final cleanup

Delete this handoff file before completion and ensure it is absent from final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head SHA / base SHA
- exact changed files
- whether a reusable comparator was extracted
- campaign grouping semantics
- no-look-ahead semantics
- exact test results
- exact RuboCop result
- any design deviation or performance concern
