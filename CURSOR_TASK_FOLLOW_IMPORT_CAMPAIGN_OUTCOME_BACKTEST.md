# Cursor task: Follow Import campaign outcome backtest

## Why this PR

PR #143 added campaign-level linked-negative overlap analysis.

The first production campaign export (30 minute max_gap) produced a strong calibration pattern:

- 24 campaigns / 21 subjects
- 12 campaigns with cross-subject overlap
- no same-subject overlap
- subject 16451 campaign: historical 13133 overlap 231, stored-negative containment 0.6507
- subject 18158 campaign: historical 13133 overlap 231, containment 0.6507
- subject 26453 campaign: historical 13133 overlap 229, containment 0.6451
- those three campaigns had very different campaign sizes, so current-target ratio/Jaccard stayed much smaller while historical-negative containment remained stable
- later records show 16451, 18158, and 26453 each received a subsequent suspend action after their campaign ended

This does NOT establish causality or an identity link.

The next calibration question is factual:

> After a completed campaign, what moderation actions were observed later, and on what timescale?

We need to join outcomes to the existing campaign feature rows **without leaking future actions into the feature computation**.

## Base / branch

Work on:

`analysis/follow-import-campaign-outcome-backtest`

Base commit:

`5f1dfd3c71de3561f2aca009184c07a1520c0827`

(PR #143 merged)

## Goal

Add a read-only offline backtest service, preferably:

`Moderation::FollowImportCampaignOutcomeBacktestService`

It should:

1. call `FollowImportCampaignNegativeTargetOverlapService` for the caller-supplied batch cohort
2. preserve that service's feature semantics and no-look-ahead
3. join later `ModerationAction` rows for the **current campaign subject**
4. keep prior / during / post-campaign actions distinct
5. report right-censored outcome-window summaries
6. never feed outcome information back into overlap features, scores, gates, or policy

## API

Suggested:

```ruby
Moderation::FollowImportCampaignOutcomeBacktestService.new.call(
  batches,
  max_gap: 30.minutes,
  observation_end: Time.now.utc,
  horizons: {
    '1h' => 1.hour,
    '6h' => 6.hours,
    '24h' => 24.hours,
    '7d' => 7.days,
  }
)
```

Caller supplies batches.

Do not default to `FollowImportBatch.all`.

`observation_end` must be explicit in the result so censorship is auditable.

Make horizons injectable.

## Critical temporal separation

The feature row comes from PR #143 and freezes historical evidence at:

`campaign.started_at`

Do not change that.

For moderation actions on the **current campaign subject**, classify them:

### prior_actions

`performed_at <= campaign.started_at`

Historical context only.

### during_campaign_actions

`campaign.started_at < performed_at <= campaign.ended_at`

Report separately.

Do NOT treat these as post-campaign outcomes because the campaign feature includes the full completed campaign target union, including targets after the action.

### post_campaign_actions

`campaign.ended_at < performed_at <= observation_end`

These are the valid offline outcome labels for completed-campaign analysis.

Actions after `observation_end` are invisible to this run.

This separation is mandatory.

## Outcome row

For every campaign, keep the original #143 campaign feature row intact and add an outcome block such as:

```text
outcome:
  observation_end
  prior_action_count
  prior_action_types
  latest_prior_action_at

  during_campaign_action_count
  during_campaign_action_types
  first_during_campaign_action_at

  post_campaign_action_count
  post_campaign_action_types
  first_post_campaign_action:
    action_id
    action_type
    performed_at
    seconds_after_campaign_end

  first_post_action_by_type:
    warn: ...
    limit: ...
    freeze: ...
    suspend: ...
    delete: ...
    other: ...
```

Use factual action types only.

Do not create an interpretive "severe" grouping in this PR.

If there are multiple actions of one type, first occurrence is enough for first-by-type metadata, but total action counts/types should remain factual.

## Horizon summaries and right censoring

For each requested horizon, report at least:

- any moderation action
- each individual ModerationAction action_type

Suggested per outcome/horizon summary:

```text
subjects_or_campaigns_reached
campaigns_eligible
campaigns_censored
reach_rate
time_to_first_action_seconds distribution
```

Campaign-level denominator is acceptable and preferred here.

Censoring semantics:

A campaign is **reached** for a horizon if a qualifying post-campaign action occurs within:

`campaign.ended_at < action.performed_at <= campaign.ended_at + horizon`

A reached campaign is eligible even if the full horizon has not elapsed by observation_end, because the event was observed.

A non-reached campaign is eligible only if:

`campaign.ended_at + horizon <= observation_end`

Otherwise it is right-censored and excluded from the denominator.

Example:

- campaign ended 30 minutes ago
- observation_end = now
- suspend happened 5 minutes after campaign end
- for 1h horizon: reached + eligible even though 1h has not elapsed
- if no suspend happened: censored for 1h

This should mirror the careful right-censoring semantics already used in `FollowGateBacktestCohortService`.

## No future leakage into feature rows

Outcome queries must never alter:

- historical snapshot eligibility
- best overlap match
- overlap_count
- current_target_overlap_ratio
- stored_negative_containment
- jaccard
- campaign grouping

The backtest service may compose the campaign service and append an outcome block.

Do not re-run #143 with observation_end as `as_of`.

## Useful top-level result

Suggested:

```text
generated_at
observation_end
max_gap_seconds
horizons_seconds
campaign_count
subject_count
campaigns_with_cross_subject_overlap
outcomes:
  any_action:
    1h: ...
    6h: ...
    24h: ...
    7d: ...
  warn:
  limit:
  freeze:
  suspend:
  delete:
  other:
campaigns
elapsed_seconds
```

You may preserve #143's coverage/distributions too, or nest the original campaign-analysis result if that produces a cleaner stable shape.

Prefer not to duplicate the feature calculations.

## Analysis grouping sensitivity

Do NOT choose a "correct" max_gap in this PR.

Keep max_gap injectable.

The operator should be able to run the same outcome backtest for 5m / 15m / 30m / 60m later.

30m remains a calibration heuristic, not a risk threshold.

## Guardrails

This is OFFLINE CALIBRATION only.

Do not add:

- score
- risk label
- "high overlap" label
- prediction
- recommendation
- threshold mapping
- precision/recall classification based on a new threshold
- AdaptiveFollowGate changes
- RiskEvaluation changes
- ModeratorRecommendation changes
- enforcement
- identity inference
- "same person"
- "ban evasion"
- DB migration
- writes

A later moderation action is an observed outcome, not proof that the overlap caused it.

## Read-only / performance

Preload/query ModerationAction rows efficiently for all campaign subject ids and relevant time range.

Avoid one ModerationAction query per campaign if practical.

This is an offline caller-selected cohort tool, so do not broaden into major indexing/schema work.

Return elapsed_seconds.

## Tests

Add focused specs covering at least:

1. prior action is reported only as prior context
2. action between campaign start/end is reported as during-campaign, not post outcome
3. action after campaign end is a post-campaign outcome
4. action after observation_end is excluded
5. first post action metadata and seconds-after-end are correct
6. first action per type is deterministic
7. no action + full horizon elapsed = eligible non-reacher
8. no action + horizon not fully elapsed = censored
9. observed action within horizon counts as reached+eligible even when horizon has not fully elapsed
10. action outside 1h but inside 6h counts only for the 6h+ windows
11. individual action_type summaries remain separate
12. repeated campaigns for one subject use campaign-specific end times correctly
13. feature row from #143 is preserved unchanged apart from added outcome metadata
14. no outcome action leaks into overlap feature computation
15. empty cohort stable shape
16. read-only guarantees
17. existing #141/#142/#143 focused specs remain green

Include an integration-style regression modeled after the production shape:

- campaign A has strong cross-subject overlap
- campaign ends
- current subject gets suspend a few minutes later
- verify overlap was computed at campaign start baseline
- verify suspend appears only in post-campaign outcome
- verify no policy decision is created

## Validation

Run at least:

```bash
bundle exec rspec spec/services/moderation/follow_import_campaign_outcome_backtest_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_campaign_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_cohort_service_spec.rb
bundle exec rspec spec/services/moderation/linked_negative_target_overlap_comparator_spec.rb
bundle exec rubocop app/services/moderation/follow_import_campaign_outcome_backtest_service.rb spec/services/moderation/follow_import_campaign_outcome_backtest_service_spec.rb
```

If additional existing files are changed, run their focused specs too.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add outcome backtest for Follow Import recurrence campaigns`

PR body must explicitly state:

- read-only / offline calibration
- composes #143 feature rows
- feature historical baseline remains campaign.started_at
- outcomes are only actions after campaign.ended_at
- actions during campaign are reported separately and are not outcome labels
- observation_end + horizons are explicit
- right censoring is handled
- action types stay factual/separate
- no score/recommendation/gate/enforcement
- no identity inference
- no DB migration

## Final cleanup

Delete this handoff file before completion and ensure it is absent from final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head SHA / base SHA
- changed files
- exact temporal classification semantics
- exact censoring semantics
- whether ModerationAction queries are batched/preloaded
- exact RSpec results
- exact RuboCop result
- any deviation / unresolved concern
