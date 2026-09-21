# Cursor task: expose Follow Import recurrence observation in subject diagnostics

## Why this PR

PRs #141-#144 established an analysis-only Follow Import recurrence pipeline:

- single-batch linked-negative overlap
- cohort summaries
- campaign aggregation
- outcome backtest with no-look-ahead and right censoring

Production sensitivity analysis at a fixed observation_end compared max_gap = 5m / 15m / 30m / 60m.

Observed:

- 15m, 30m, and 60m produced the same 24 campaigns / 12 cross-subject-overlap campaigns
- subjects 16451 and 18158 were identical at all four gap settings:
  - historical subject 13133
  - overlap 231 / stored linked-negative set 355
  - stored_negative_containment 0.650704...
- subject 26453:
  - at 15m / 30m / 60m: one 14-batch campaign, overlap 229 / 355, containment 0.645070...
  - at 5m: the same activity fragments into three campaigns
    - 26453:42: best historical 18158, overlap 51 / 139, containment 0.366906...
    - 26453:47: best historical 13133, overlap 178 / 355, containment 0.501408...
    - 26453:52: best historical 18158, overlap 43 / 139, containment 0.309353...
- the same eventual suspend appears as a post-campaign outcome on all three 5m fragments, demonstrating why too-small campaign gaps can duplicate a single subject-level outcome
- non-suspended cross-overlap campaigns remained low; the strongest observed non-suspend containment in this cohort was about 0.062
- this is still a small, related sample. It is NOT enough to choose a risk threshold or calibrated score.

The next step is operator observability, not scoring.

## Base / branch

Work on:

`analysis/follow-import-recurrence-diagnostics`

Base commit:

`b0af350c3998074701b296d679e3c66c5ce1c029`

(PR #144 merged)

## Goal

Add a read-only service that exposes the latest observed Follow Import campaign recurrence facts for one moderation subject, then surface those facts in `Moderation::SubjectDiagnosticsService`.

Do NOT change RiskEvaluation scoring, Follow Gate decisions, moderator recommendation policy, or enforcement.

Suggested new service:

`Moderation::FollowImportRecurrenceObservationService`

## API

Suggested:

```ruby
service.call(
  subject_or_account,
  now: Time.now.utc,
  lookback: 7.days,
  max_gap: 30.minutes
)
```

Defaults are analysis/diagnostic heuristics only.

Return the effective `lookback_seconds` and `max_gap_seconds` so output is auditable.

## Subject resolution

Read-only only.

- If passed a ModerationSubject, use it.
- If passed an Account, find existing ModerationSubject by account_id.
- Never call `ModerationSubject.for_account!` or otherwise create anything.
- If no subject exists, return a stable unavailable shape.

## Batch selection / no future leakage

For the resolved subject, select only:

`now - lookback <= imported_at <= now`

Never include future batches.

Caller-facing output should make this cutoff explicit.

Do not default to all subjects.

## Campaign composition

Compose:

`Moderation::FollowImportCampaignNegativeTargetOverlapService`

Do not reimplement grouping or overlap.

Pass only this subject's bounded batches.

Use injectable `max_gap`; default 30.minutes remains the existing grouping heuristic, NOT a risk threshold.

Select the latest observed campaign deterministically, preferably by:

1. ended_at desc
2. started_at desc
3. campaign_index / stable key

The service is a "campaign observed so far" view. It does not need to claim that a recent campaign is definitively finished.

## Output

Stable suggested shape:

```text
available
subject_id
generated_at
lookback_seconds
max_gap_seconds
batch_count
campaign_count
latest_campaign:
  campaign_key
  started_at
  ended_at
  duration_seconds
  seconds_since_last_batch
  batch_count
  target_rows
  comparable_unique_target_count
  unresolved_or_unmapped_target_rows

  same_subject:
    matching_snapshot_count
    best_match

  cross_subject:
    matching_snapshot_count
    best_match
```

Best match should keep the factual fields already produced by #143, e.g.:

- snapshot_id
- historical_subject_id
- action_types
- latest_action_performed_at
- historical_fingerprint_complete
- stored_linked_negative_target_count
- reported_linked_negative_target_count
- overlap_count
- current_target_overlap_ratio
- stored_negative_containment
- jaccard

No target subject ID arrays.

No post-campaign outcome labels here.

No action against the current subject is needed here.

## Stable unavailable / empty shapes

Distinguish at least:

- no moderation subject
- no Follow Import batches in lookback
- batches exist but no campaign row (defensive)

Use factual reason strings, not risk labels.

## SubjectDiagnostics integration

Add the observation under the existing `follow_import` block, for example:

```text
follow_import:
  batch_count
  target_total
  ...
  recurrence_observation:
    ...
```

Prefer constructor injection so specs can provide a fake recurrence observer.

Do not duplicate expensive recurrence computation if diagnostics already has a suitable cached result; otherwise one bounded read-only pass is acceptable.

Keep the existing evaluation and follow_gate outputs unchanged.

## Observation-quality notes

Add concise notes making these semantics explicit:

- cross-subject linked-negative overlap is behavioral recurrence evidence, NOT identity proof
- fingerprint completeness false means observed overlap is a lower bound
- completeness nil means unknown, not complete
- max_gap is a grouping heuristic, not a policy threshold
- absence of recurrence evidence is not proof of safety, especially with partial remote coverage

Do not write loaded labels like "ban evasion" or "same actor".

## Important guardrails

DO NOT:

- add thresholds
- add a recurrence score
- change `RiskEvaluationService::DEFAULT_PARAMS`
- make `follow_import` subscore non-zero
- change AdaptiveFollowGateDecisionService
- change ModeratorRecommendationService
- add friction / recommendation based on recurrence
- infer identity
- call it "same user", "sockpuppet", "ban evasion", or similar
- add DB migration
- write observations to DB in this PR
- use target_key_hash as target identity
- use correlated negative IDs
- include raw target subject lists

This PR is diagnostics/observability only.

## Tests

Add focused specs covering at least:

1. ModerationSubject input resolves directly and remains read-only
2. Account input uses existing subject without creating one
3. missing subject returns stable unavailable shape
4. no batches in lookback returns stable empty/unavailable observation
5. only batches with imported_at <= now are included
6. batches older than lookback are excluded
7. multiple campaigns select the latest deterministically
8. target union / overlap values come from the composed campaign service rather than duplicated math
9. complete / incomplete / unknown fingerprint state is preserved
10. same-subject and cross-subject blocks remain separate
11. no target ID arrays leak into diagnostics output
12. max_gap and lookback are exposed
13. SubjectDiagnostics includes recurrence_observation under follow_import
14. SubjectDiagnostics evaluation output is unchanged
15. SubjectDiagnostics follow_gate output is unchanged
16. read-only guarantee
17. existing #141-#144 focused specs remain green
18. existing SubjectDiagnostics specs remain green

Add a production-shaped regression example:

- subject has a recent multi-batch campaign
- campaign best match is a different historical moderated subject
- linked-negative containment is factual in output
- no score / recommendation / proposed friction changes as a consequence

## Performance

Bound the batch query by subject + lookback + now.

This is operator diagnostics, not an all-subject population scan.

Reuse the existing campaign service and comparator.

No new schema/index work unless a real focused spec demonstrates it is necessary; avoid scope creep.

## Validation

Run at least:

```bash
bundle exec rspec spec/services/moderation/follow_import_recurrence_observation_service_spec.rb
bundle exec rspec spec/services/moderation/subject_diagnostics_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_campaign_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_campaign_outcome_backtest_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb
bundle exec rspec spec/services/moderation/linked_negative_target_overlap_comparator_spec.rb
bundle exec rubocop app/services/moderation/follow_import_recurrence_observation_service.rb app/services/moderation/subject_diagnostics_service.rb spec/services/moderation/follow_import_recurrence_observation_service_spec.rb spec/services/moderation/subject_diagnostics_service_spec.rb
```

If additional files change, run their focused specs too.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Expose Follow Import recurrence in subject diagnostics`

PR body must explicitly state:

- read-only diagnostics / observability only
- composed from #143 campaign overlap semantics
- bounded to subject + lookback + now
- default 30m max_gap is a grouping heuristic only
- sensitivity data showed 15m / 30m / 60m stable, while 5m fragmented one subject into three campaign rows; this motivates surfacing the heuristic rather than treating it as policy
- cross-subject recurrence is not identity proof
- no score / RiskEvaluation / recommendation / gate / enforcement change
- no migration
- no raw target lists

## Final cleanup

Delete this handoff file before completion and ensure it is absent from final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head SHA / base SHA
- exact changed files
- observation service API
- exact subject/batch cutoff semantics
- exact latest-campaign selection semantics
- SubjectDiagnostics integration shape
- exact RSpec results
- exact RuboCop result
- any design deviation or performance concern
