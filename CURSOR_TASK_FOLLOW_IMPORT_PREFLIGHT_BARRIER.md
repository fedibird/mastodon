# Cursor task: add a durable preflight barrier for moderator-held Follow Imports

## Context / intent

We want Follow Import to support a human-in-the-loop moderation path **before any imported follow is dispatched**.

The later policy goal is:

1. record the complete Follow Import target set up front
2. compare the new import against historical, action-linked negative-target fingerprints from previously moderated subjects
3. if the import looks materially similar (for example, it contains many of the same recipients who previously rejected a moderated subject), hold the import before execution
4. surface a moderator review request
5. moderator either:
   - releases it to normal processing, or
   - stops the import before the follow burst happens

Important: recurrence is behavioral evidence, not identity proof. A review hold is not an automatic abuse verdict.

Before adding recurrence thresholds or moderator UI, we need a race-safe execution barrier so **zero follow additions and zero overwrite removals can escape before preflight finishes**.

This PR is that foundation only.

## Branch / base

Work on:

`feature/follow-import-moderation-preflight-barrier`

Base commit:

`eb0785ef5da8856840937323e7d7ca9e77baaaa7`

(#145 merged)

## Current execution boundary

Today `ImportService#import_follows!` does roughly:

1. parse the full CSV
2. `record_follow_import_batch!`
3. immediately hand the batch to:
   - legacy `FollowImport::BatchExecutionWorker`, or
   - global scheduler via scheduler-owned batch visibility
4. enqueue overwrite-mode unfollows separately

The full target set is therefore available before actual follows execute, which is exactly where preflight belongs.

However, for scheduler-owned batches there is a race: once the batch is committed as an operational scheduler-owned batch, a global scheduler tick may claim targets before a later "hold" flag is written.

Therefore **new operational batches must be born non-dispatchable**.

## Goal

Add a durable batch-level preflight execution state that prevents any Follow Import execution until the batch is explicitly released.

This PR MUST NOT add recurrence thresholds, scoring, moderator review UI, notifications, or automatic moderation decisions.

It is an execution-safety primitive.

## Suggested state model

Add an explicit enum to `FollowImportBatch`, name can be chosen to fit project style, for example:

`preflight_state`

Suggested semantic states:

- `screening`
  - newly recorded operational batch
  - not executable by legacy worker
  - not visible to authoritative global planning
  - overwrite removals must not run
- `ready`
  - preflight completed and normal processing may begin
- `review_required`
  - future moderator-hold state
  - no execution
- `stopped`
  - future moderator decision to abandon the import
  - no execution

Do not call these states "safe", "malicious", "abusive", etc.

If you prefer different names, preserve these semantics.

### Migration compatibility

Existing persisted batches must keep their current behavior.

Migration/backfill/default semantics must ensure existing rows become effectively `ready`, not suddenly held.

But **new operational rows created through FollowImportRecorder after this PR must be created as `screening` before they become visible to dispatch**.

Do not rely only on a DB default of ready for new recorder rows.

## Release primitive

Add a small, explicit service for transitioning an operational batch from `screening` to `ready`, e.g.:

`FollowImport::PreflightReleaseService`

or a similarly named service.

It should:

- be idempotent
- use row locking / compare-current-state semantics
- never release `review_required` or `stopped` accidentally
- return a factual result
- write no moderation inference
- not enqueue work by itself unless that is clearly safer architecturally

For this foundational PR, normal imports should still behave exactly as before by immediately releasing after batch recording.

That means:

1. recorder creates batch as `screening`
2. ImportService calls a neutral/default preflight step that releases to `ready`
3. only after ready does normal handoff proceed

This creates the insertion point for the next PR without changing user-visible execution behavior yet.

## Legacy worker barrier

`FollowImport::BatchExecutionWorker` must refuse to do ANY execution-side work for a non-ready batch.

The refusal must happen immediately after loading the batch, before:

- load snapshot
- candidate selection
- gate evaluation
- target claim
- enqueue
- reschedule
- Import cleanup/finalization

A stale/duplicate worker for a held batch must be harmless.

Do not treat non-ready as completed.

Do not destroy the retained Import.

## Global scheduler barrier

Authoritative GLOBAL planning must include only operational + scheduler-owned + `ready` batches.

Update the canonical scope used by global planning.

Also ensure the mutation boundary / executor has defense-in-depth: if a stale plan contains an entry whose batch has since become non-ready, it must not claim it.

Do not rely only on planner filtering.

Shadow planner behavior:

- it is acceptable to keep shadow visibility broader only if explicitly useful and clearly labeled,
- but do not let shadow planning accidentally imply executable work.
- Prefer simple, auditable semantics.

Document the choice.

## Pending/backlog metrics

Review any Follow Import backlog / dispatch count code that assumes all operational pending rows are executable.

If planning counts should exclude non-ready batches, make that distinction explicit.

Do not silently redefine historical/operational counts.

If both are useful:
- operational pending = all operational provenance
- executable/planning pending = only ready rows

Preserve observability.

## ImportService ordering

For the normal path after this PR:

```text
parse CSV
  -> record batch + targets (screening)
  -> neutral preflight release (ready)
  -> handoff / scheduler eligibility
  -> overwrite removals if applicable
```

The future moderation policy will replace "neutral preflight release" with:
- ready, or
- review_required

### Critical overwrite requirement

Today overwrite-mode unfollows are intentionally enqueued separately from imported follow additions.

After this PR, **overwrite removals must only be enqueued after the batch is ready**.

If a future review_required batch is held, neither:
- imported follow additions,
nor
- overwrite removals

may execute.

This is required for "stop before behavior begins" semantics.

## Retry / idempotency behavior

ProcessImportWorker may retry the same Import.

Existing `import_id` idempotency remains authoritative.

Required behavior:

- existing screening batch must not be duplicated
- neutral release may safely be retried
- ready batch may proceed with the current existing handoff semantics
- review_required/stopped are not released by generic retry paths
- a retry must never convert review_required/stopped back to ready

Think carefully about the current:

`existing_follow_import_batch`

path.

## Recorder failure / legacy fallback

Current GLOBAL-off logic permits tolerant recording and may fall back to legacy direct import if no durable batch can be established.

This PR should preserve current behavior while moderation preflight is not yet enforced.

However, structure the code so the next PR can require a durable batch when moderator preflight enforcement is enabled.

Add a clear TODO/comment if needed.

Do NOT silently remove the legacy fallback in this PR unless required for correctness.

## Progress / completion semantics

No user-facing moderator state UI is required in this PR.

But ensure:

- screening/review_required batch is not treated as completed
- its Import file remains retained
- completion scheduler does not send a false completion notification
- stopped is not automatically treated as successfully completed

If existing code naturally satisfies this, add regression specs rather than extra behavior.

Do not add a target-level `cancelled` state in this PR unless absolutely required.

## No scoring / policy in this PR

DO NOT:

- call recurrence observation to decide anything
- introduce overlap thresholds
- add a risk score
- change RiskEvaluationService
- change AdaptiveFollowGateDecisionService
- change ModeratorRecommendationService
- infer identity
- create moderator queue/UI
- send notification/email
- add automatic suspend/limit
- add current-subject ModerationAction
- use target_key_hash as identity evidence

This PR only guarantees a safe preflight barrier.

## Tests

Add focused coverage for at least:

1. newly recorded operational batch starts screening
2. existing/backfilled rows remain effectively ready
3. neutral preflight releases screening -> ready
4. neutral release is idempotent
5. generic release does NOT release review_required
6. generic release does NOT release stopped
7. legacy BatchExecutionWorker on screening batch:
   - claims zero
   - enqueues zero relationship workers
   - does not finalize/destroy Import
   - does not reschedule as if progress occurred
8. same for review_required
9. same for stopped
10. ready legacy batch retains existing execution behavior
11. GLOBAL planning excludes non-ready scheduler-owned operational batches
12. GLOBAL planning includes ready scheduler-owned operational batches
13. stale global plan / executor cannot claim a batch that became non-ready after planning
14. operational backlog/provenance counts remain auditable
15. planning/executable counts exclude non-ready where appropriate
16. overwrite-mode unfollows are not enqueued before ready
17. normal neutral-release path still enqueues overwrite removals after ready
18. ProcessImportWorker retry with an existing ready batch does not revert state
19. retry with review_required/stopped does not release it
20. completion notification is not emitted merely because a batch is held
21. Import/CSV remains retained while non-ready
22. no moderation/risk decision output added
23. focused existing dispatch/pacing tests remain green

## Concurrency test

Add at least one test proving the scheduler race is closed:

- create scheduler-owned operational batch in screening state
- run the global planning/claim path
- assert zero target transitions
- release to ready
- run again
- assert it becomes claimable normally

Also cover defense-in-depth if a plan was produced when ready and the batch is moved to review_required before executor mutation.

## Audit the following likely files

At minimum inspect:

- app/models/follow_import_batch.rb
- app/services/moderation/follow_import_recorder.rb
- app/services/import_service.rb
- app/workers/follow_import/batch_execution_worker.rb
- app/services/follow_import/dispatch_scheduler.rb
- app/services/follow_import/pending_batch_source.rb
- app/services/follow_import/dispatch_executor.rb
- app/services/follow_import/dispatch_counts.rb
- app/services/follow_import/progress_service.rb
- completion notification scheduler/service
- relevant migrations/schema/specs

Do not change unrelated pacing semantics.

## Design note for next PR

Leave a concise code comment or PR-body note describing the intended next layer:

After a batch is durably recorded in `screening`, a preflight moderation evaluator can inspect the entire known target set and transition exactly one way:

- `screening -> ready`
- `screening -> review_required`

A moderator workflow can later transition:

- `review_required -> ready` (release)
- `review_required -> stopped` (stop)

No automatic path should transition `review_required -> ready`.

This PR need not implement those moderator endpoints yet.

## Validation

Run focused specs for all modified dispatch/import components.

At minimum include relevant existing specs around:

- ImportService follow import
- FollowImportRecorder
- BatchExecutionWorker
- DispatchScheduler
- PendingBatchSource
- DispatchExecutor
- DispatchCounts
- completion scheduler/progress if touched

Run RuboCop on modified Ruby/spec files.

No new lint tooling.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add a preflight execution barrier for Follow Import`

PR body must explicitly state:

- execution-safety foundation only
- new batches are born non-dispatchable
- normal path immediately releases them, so behavior is unchanged
- legacy and global paths both enforce ready state
- stale global plans are fenced at mutation boundary
- overwrite removals are behind the same barrier
- no recurrence threshold / score / moderator decision yet
- no identity inference
- existing batches preserve behavior

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head/base SHA
- changed files
- migration semantics for existing vs new batches
- exact state machine
- exact legacy-worker refusal point
- exact global planner + executor fencing
- overwrite-mode ordering
- retry semantics
- Import retention semantics
- RSpec results
- RuboCop result
- any deviation / unresolved race
