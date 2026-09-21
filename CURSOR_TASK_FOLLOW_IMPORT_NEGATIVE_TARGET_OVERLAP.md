# Cursor task: analysis-only Follow Import negative-target overlap

## Goal

Implement the first **analysis-only** building block for Problematic Target Overlap / Cross-account Recurrence.

We already persist, at moderation-action time, strong linked negative-target sets in:

- `ModerationEvidenceSnapshot#linked_negative_target_subject_ids`
- `summary['linked_negative_target_count']`

A new Follow Import batch should be comparable against those historical linked-negative sets **without** adding any score, recommendation, gate decision, or enforcement.

This PR is deliberately narrow. It is not full import-list similarity and it is not identity inference.

## Base / branch

Work on:

`analysis/follow-import-negative-target-overlap`

It was created from current `fedibird` at:

`a93924137a19750263a7b4b83906c76070be7fec`

Do not rebase onto unrelated work unless necessary.

## Required implementation

Add a read-only service, preferably:

`app/services/moderation/follow_import_negative_target_overlap_service.rb`

with a simple API such as:

```ruby
Moderation::FollowImportNegativeTargetOverlapService.new.call(batch, as_of: batch.imported_at)
```

Exact method organization may follow repository conventions, but preserve the semantics below.

### 1. Current comparison set

For the supplied `FollowImportBatch`:

- use unique, non-NULL `FollowImportTarget#target_subject_id`
- duplicate targets count once
- unresolved / unmapped targets do not enter the overlap denominator
- report enough counts to make this limitation explicit:
  - batch target rows
  - unique comparable resolved targets
  - unresolved/unmapped target rows

Do not use `target_key_hash` to infer identity.

### 2. Historical evidence source

Compare only against `ModerationEvidenceSnapshot` rows that are actually linked to at least one `ModerationAction`.

The historical comparison set is ONLY:

`snapshot.linked_negative_target_subject_ids`

Do **not** merge in:

- `correlated_negative_target_subject_ids`
- all targets from the historical Follow Import
- general contacted targets
- popular/common target heuristics

The purpose of this first PR is specifically:

> Does this new import contain many of the same recipients who previously gave a strongly linked explicit negative response to a moderated subject?

### 3. No look-ahead

This service must be safe for historical backtesting.

By default, use `batch.imported_at` as the comparison cutoff. An explicit `as_of:` may be accepted for tests/operator analysis.

A historical moderation action/snapshot must not be considered if the linked `ModerationAction#performed_at` is after `as_of`.

Do not accidentally use future moderation knowledge when replaying old batches.

### 4. Result shape

Return factual analysis metadata, not a verdict.

Suggested top-level fields:

```text
batch_id
subject_id
as_of
target_rows
comparable_unique_target_count
unresolved_or_unmapped_target_rows
candidate_snapshot_count
matching_snapshot_count
matches
```

Each matching historical snapshot should expose enough information to audit the comparison, for example:

```text
snapshot_id
historical_subject_id
same_subject
action_ids
action_types
latest_action_performed_at
stored_linked_negative_target_count
reported_linked_negative_target_count
historical_fingerprint_complete
overlap_count
current_target_overlap_ratio
stored_negative_containment
jaccard
```

Naming may be improved, but keep the distinctions explicit.

Definitions:

- `overlap_count` = intersection size
- `current_target_overlap_ratio` = overlap / current unique comparable targets
- `stored_negative_containment` = overlap / number of stored linked-negative IDs
- `jaccard` = overlap / union(current comparable targets, stored linked-negative IDs)

Return raw floats; presentation can round later.

Only include rows with `overlap_count > 0` in `matches`, but report how many eligible snapshots were scanned.

Sort matches deterministically, strongest factual overlap first (e.g. overlap count desc, containment desc, latest action time desc, stable id tie-break).

### 5. Fingerprint truncation must be explicit

`EvidenceSnapshotService::MAX_FINGERPRINT_IDS` caps persisted IDs.

Therefore do not imply that a stored fingerprint is always complete.

Use:

- `summary['linked_negative_target_count']` as the reported total at snapshot time
- actual stored linked-negative ID array length as the comparison-set size

Expose whether the fingerprint is complete, e.g.:

```ruby
historical_fingerprint_complete =
  reported_linked_negative_target_count <= stored_linked_negative_target_count
```

If incomplete, the overlap is a **lower-bound observation** against the stored subset.

Do not "correct" or estimate missing IDs.

### 6. Same subject vs cross-account

Do not discard same-subject historical snapshots.

Expose a `same_subject` boolean so later analysis can distinguish:

- recurrence by the same moderation subject
- recurrence by a different subject

Do not claim two different subjects are the same person.

### 7. Read-only / no policy coupling

This PR MUST NOT modify:

- `Moderation::RiskEvaluationService`
- `Moderation::AdaptiveFollowGateDecisionService`
- `Moderation::ModeratorRecommendationService`
- Follow Import dispatch / pacing
- moderation actions
- follow creation / rejection behavior

No automatic score.
No risk label.
No threshold such as "high overlap".
No moderator recommendation.
No enforcement.
No database migration unless a real blocker is discovered and documented before doing it.

The service must write nothing.

## Tests

Add a focused spec, preferably:

`spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb`

Cover at minimum:

1. **Basic linked-negative overlap**
   - current batch targets A/B/C
   - prior moderated snapshot linked-negative set A/B/X
   - overlap = 2
   - current ratio = 2/3
   - stored containment = 2/3
   - Jaccard = 2/4

2. **Duplicate current targets**
   - duplicate target rows count once in the comparable set

3. **Unresolved targets**
   - NULL `target_subject_id` is reported but not included in overlap denominator

4. **Correlated-only evidence is excluded**
   - historical `correlated_negative_target_subject_ids` must not create a match

5. **No look-ahead**
   - an action performed after `as_of` is ignored

6. **Same-subject marker**
   - historical snapshot for the same subject is included and marked `same_subject=true`

7. **Cross-subject marker**
   - other subject is not inferred to be identical; only `same_subject=false`

8. **Fingerprint truncation / incompleteness**
   - reported linked-negative count greater than stored ID count yields incomplete coverage metadata
   - metrics are calculated only from the stored IDs

9. **No-overlap**
   - no match row / matching count zero

10. **Read-only**
    - calling the service does not change subjects, interactions, rejections, actions, snapshots, batches, targets, follows, blocks, or mutes

If practical, also cover a tombstoned/detached historical moderation subject to prove the analysis still works from deletion-safe retained evidence.

## Important semantic guardrails

Preserve these distinctions:

- Linked means a strong preceding-contact association, **not causal proof**.
- Historical negative-target overlap means behavior recurrence, **not identity proof**.
- Full target-list similarity is intentionally NOT implemented here.
- A repeated legitimate import can have high full-list overlap; that fact alone is not a risk signal.
- The stronger fact in this PR is overlap with recipients who previously gave an explicit qualified negative response.
- Absence of overlap is not evidence of safety; fingerprints can be incomplete and remote observation coverage is partial.

## Validation

Run at least:

```bash
bundle exec rspec spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
bundle exec rspec spec/services/moderation/evidence_snapshot_service_spec.rb spec/services/moderation/behavioral_metrics_service_spec.rb
bundle exec rubocop app/services/moderation/follow_import_negative_target_overlap_service.rb spec/services/moderation/follow_import_negative_target_overlap_service_spec.rb
```

If touching any additional existing file, run its focused spec too.

Do not paper over pre-existing unrelated failures.

## PR

Create **one Draft PR** against `fedibird`.

Suggested title:

`Add analysis-only Follow Import negative-target overlap`

PR body must state clearly:

- analysis-only / read-only
- compares current resolved import targets only with historical **linked negative target** fingerprints attached to moderation actions
- no full-list similarity
- no score/recommendation/enforcement
- no identity inference
- historical replay uses an `as_of` cutoff and has no look-ahead
- fingerprint truncation is surfaced explicitly
- no migration (unless genuinely required)

## Final cleanup

This file is a temporary Cursor handoff.

Before reporting completion:

1. delete this instruction file from the branch
2. make sure it is absent from the final PR diff
3. leave only implementation/spec changes (and a persistent implementation doc only if genuinely needed)

## Completion report back to ChatGPT

Return:

- Draft PR URL / number
- head SHA
- base SHA
- exact changed files
- brief result-shape summary
- confirmation that no score/gate/enforcement changed
- confirmation of no-look-ahead semantics
- RSpec commands + exact results
- RuboCop command + exact result
- any unresolved concern or design deviation
