# Cursor task: connect Follow Import to Action Review with moderator approve/stop

## Context

Merged foundations:

- #147: Follow Import durable preflight barrier
  - new operational batches are born `screening`
  - only `ready` batches execute
  - legacy + GLOBAL both fence non-ready
  - overwrite unfollows are behind the barrier
- #148: generic Action Review persistence + policy engine
- #149: staff review queue + admin policy settings UI

Now connect **Follow Import** as the first real Action Review operation.

This PR should make the site setting operational in a deliberately conservative first phase:

- `off` -> normal processing
- `always` -> hold every Follow Import for moderator decision
- `high / medium / low` -> currently receive signal=`none`, so they do NOT hold yet
  - these modes remain reserved for the later calibrated automated detector
  - update UI hint text so admins are not misled

Do NOT add recurrence thresholds or automated low/medium/high classification in this PR.

## Branch / base

Work on:

`feature/follow-import-action-review`

Base commit:

`1ba9144b4ead95091c9b9f02ebe2c6ddf32f8334`

(#149 merged)

## Goal

End-to-end behavior:

```text
Follow Import uploaded
  -> complete batch + targets recorded as screening
  -> Action Review policy decision (signal=none)
     -> no review required:
          screening -> ready
          normal execution
     -> review required:
          create pending ActionReviewRequest
          screening -> review_required
          zero follow additions
          zero overwrite removals

Moderator queue
  -> Approve and execute
       request pending -> approved
       batch review_required -> ready
       durable resume requested
       processing resumes
  -> Stop
       request pending -> rejected
       batch review_required -> stopped
       no import behavior executes
       raw CSV becomes cleanup-eligible
```

"Rejected" means the **operation was stopped**. It is NOT a moderation action against the account and must not suspend/limit/warn the account.

Behavioral recurrence remains separate evidence work. No identity inference.

---

# Part A: Follow Import preflight policy integration

Add a dedicated service, suggested:

`FollowImport::ActionReviewPreflightService`

Do not put Action Review policy logic directly into `ImportService`.

### State behavior

For an operational FollowImportBatch:

- `ready`:
  - executable, do not re-evaluate policy
- `review_required`:
  - held, do not release automatically
- `stopped`:
  - held/stopped, never release automatically
- `screening`:
  - evaluate Action Review policy exactly once for this screening transition

Historical cohort behavior stays unchanged / non-executable as already designed.

### Policy decision

For this PR call:

```ruby
ActionReview::PolicyDecisionService.new.call(
  operation_type: 'follow_import',
  signal_level: 'none',
  evaluation_status: 'ok'
)
```

Do not call recurrence services, RiskEvaluation, Follow Gate, SubjectDiagnostics, or outcome backtests.

Semantics:

- off + none -> ready
- high + none -> ready
- medium + none -> ready
- low + none -> ready
- always + none -> review_required

This is intentional until automated review-signal calibration is ready.

### Review request snapshot

When review is required, create the request through `ActionReview::RequestService`.

- operation_type: `follow_import`
- actor_account: importer account
- resource: FollowImportBatch
- evaluator_version: nil (there is no automated detector in this PR)

Evidence should be factual/minimized, suggested schema:

```json
{
  "schema_version": 1,
  "batch_id": 123,
  "imported_at": "...",
  "mode": "merge",
  "target_count": 929,
  "resolved_target_count": 929,
  "unresolved_target_count": 0,
  "account_age_seconds": 756,
  "migration_evidence": "none",
  "dispatch_owner": "legacy"
}
```

Do NOT include:

- raw account addresses
- target_key_hash arrays
- target subject-id arrays
- recurrence identity claims
- post/profile content
- IP/email secrets

### Atomic hold creation

For screening -> review_required:

- lock the batch
- create/find the pending ActionReviewRequest
- update the batch to `review_required`
- keep those changes in one DB transaction

A failure must leave the batch non-executable and retryable.

Retry behavior:

- existing pending request must be reused
- review_required must never be auto-released
- stopped must never be auto-released
- ready must not be re-evaluated against a later policy change

### No-review path

For screening where review is not required:

- transition screening -> ready using the existing safety semantics
- no ActionReviewRequest row should be created
- continue the normal handoff/overwrite ordering

Refactor `PreflightReleaseService` only as needed; preserve its existing generic safety contract/specs.

---

# Part B: make durable batch mandatory when Action Review policy is active

Today GLOBAL-off recording failure may fall back to direct legacy bulk follow execution.

That fallback would bypass Action Review.

Change recording semantics:

- if `FOLLOW_IMPORT_DISPATCH_GLOBAL` is on -> existing strict durable recording
- OR if effective Follow Import Action Review policy is anything other than `off`
  -> durable batch recording is REQUIRED
  -> use strict `record_batch!`
  -> on persistence failure, raise so ProcessImportWorker retries
  -> NEVER use direct bulk fallback
- only effective policy `off` + GLOBAL-off may retain the legacy tolerant fallback

Because malformed Action Review settings conservatively resolve to `always`, they must also use strict durable recording.

Add explicit specs.

---

# Part C: generic decision dispatcher + first Follow Import adapter

Now that one operation is executable through Action Review, add a generic decision layer.

Suggested:

- `ActionReview::DecisionService`
- `ActionReview::AdapterRegistry`
- `ActionReview::Adapters::FollowImport`

Naming may vary, but keep generic dispatch separate from Follow Import implementation.

### Adapter registry

Initially only `follow_import` has a decision adapter.

Unknown/unintegrated operation must fail explicitly.

Do not make account_migration/invite/status_import approveable yet.

### Decisions

Support:

- approve
- reject

Do not use generic "dangerous/safe" semantics.

### Authorization

Add routes/actions for Action Review decisions:

- staff (moderator/admin) may approve/reject a Follow Import review
- ordinary users may not
- settings remain admin-only

Suggested routes:

```ruby
resources :action_reviews, only: [:index, :show] do
  member do
    post :approve
    post :reject
  end
end
```

Add policy methods as appropriate.

### Decision note

Allow optional moderator decision note.

Persist:

- reviewer_account_id
- reviewed_at
- decision_note

Trim/normalize blank to nil if convenient.

### Atomic state consistency

Use a transaction with deterministic lock order.

For Follow Import, lock the batch/resource and review request consistently.

#### Approve

Required source state:

- request pending
- operation_type follow_import
- resource is the matching FollowImportBatch
- batch review_required

Atomic durable result:

- request -> approved
- reviewer/reviewed_at/note persisted
- batch -> ready
- batch metadata marks that post-approval resume work is required (see Part D)

#### Reject

Required source state:

- request pending
- batch review_required

Atomic durable result:

- request -> rejected
- reviewer/reviewed_at/note persisted
- batch -> stopped

No moderation action on the account.

### Idempotency/concurrency

- repeating the SAME already-completed decision should be harmless
- approve after rejected must fail
- reject after approved must fail
- two moderators racing: exactly one terminal decision wins
- stale page submission must not flip an already-decided request
- resource mismatch/missing/wrong preflight state must fail closed

Use `lock_version` and/or row locks as appropriate; DB state is authoritative.

---

# Part D: durable post-approval resume

Do NOT rely only on one `perform_async` call after approval.

A Redis/enqueue/process crash must not leave a legacy batch permanently ready-but-never-started.

Use FollowImportBatch.metadata for durable resume bookkeeping; no migration is necessary.

Suggested keys:

- `review_resume_required_at`
- `review_resume_completed_at`

Add model helpers, e.g.:

- review_resume_required?
- review_resume_completed?
- review_resume_pending?
- mark_review_resume_required!
- mark_review_resume_completed!

### Approval transaction

When approving:

- set batch `ready`
- persist `review_resume_required_at`
- leave completed marker absent

Then after commit/best effort:

- enqueue a dedicated resume worker

Suggested:

`FollowImport::ActionReviewResumeWorker`

### Resume worker

Input should preferably be ActionReviewRequest id so it can validate the approval source.

Worker behavior:

1. load request
2. verify:
   - operation_type=follow_import
   - request approved
   - resource is FollowImportBatch
3. return if resume already completed
4. require batch ready
5. require retained Import/CSV
6. resume through the existing import execution path in an idempotent/retry-safe way
   - re-parse retained CSV
   - legacy owner: enqueue BatchExecutionWorker
   - scheduler owner: leave execution to authoritative scheduler
   - overwrite mode: enqueue the existing overwrite unfollows
7. after the resume handoff completes successfully, mark `review_resume_completed_at`
8. if no pending targets remain, the CSV may then be cleaned

It is acceptable that a crash after some Sidekiq enqueues but before the completed marker causes at-least-once replay on retry. Existing RelationshipWorker/import retry semantics are already idempotent/retry-tolerant. Document this. Do NOT claim exactly-once semantics.

### Important CSV retention race

When approval sets a scheduler-owned batch to ready, GLOBAL dispatch can start before the resume worker runs.

Therefore, while:

`review_resume_required_at present AND review_resume_completed_at absent`

the raw Import/CSV MUST NOT be deleted even if there are no pending targets.

Update BOTH execution finalizers:

- `BatchExecutionWorker#finalize_import!`
- `DispatchExecutor#release_csv_if_dispatched`

to retain the CSV while review resume is pending.

Also update `FollowImportCsvCleanupScheduler` with the same rule.

This is critical for overwrite imports: the resume worker still needs the CSV to compute absent follows.

### Recovery scheduler

Add a bounded periodic recovery worker, e.g.:

`Scheduler::FollowImportActionReviewResumeScheduler`

Every ~5 minutes is fine.

It should find approved Follow Import ActionReviewRequests whose batch:

- is ready
- has review_resume_required_at
- lacks review_resume_completed_at
- still has its Import

and enqueue `ActionReviewResumeWorker`.

Use bounded batches (e.g. 500).

Avoid scanning all historical requests indefinitely; join/filter on operation/resource/state + batch metadata.

Add it to `config/sidekiq.yml`.

This scheduler is the backstop when the immediate enqueue is lost.

---

# Part E: reject/stopped CSV cleanup

A stopped Follow Import will never execute, so the raw CSV is no longer needed.

Update `FollowImportCsvCleanupScheduler`:

- stopped batch + surviving Import -> cleanup eligible regardless of pending targets
- review_required/screening -> retain CSV
- ready with review resume pending -> retain CSV
- normal ready/completed behavior unchanged

After reject, an immediate best-effort Import destroy is acceptable, but the scheduler must remain the durable backstop.

Do not delete FollowImportBatch/targets; they remain audit/observation records.

Do not convert target rows to fake accepted/rejected states.

---

# Part F: user-facing Follow Import progress

Avoid leaving the importer with a row that forever looks "in progress".

Extend coarse user summary with neutral workflow flags:

- `review_pending`
- `stopped`

For a review_required batch:

- status label: "Waiting for review" / Japanese equivalent
- counts may remain factual
- do not expose signal/evidence/reason

For a stopped batch:

- status label: "Stopped" / neutral Japanese equivalent
- it is no longer "waiting to process"
- make the waiting display 0 or otherwise clearly non-active
- keep factual total/processed counts

Do NOT show:

- high/medium/low signal
- overlap evidence
- moderation suspicion
- historical subjects
- reason codes

This is workflow state only.

Update English + Japanese locale strings/specs.

---

# Part G: Admin queue decision UI

On Action Review show page:

For a pending, adapter-supported, valid Follow Import review:

- show "Approve and run" button
- show "Stop" button
- optional decision note field

Use confirmation on Stop if consistent with existing UI.

After decision:

- redirect back to request detail
- show neutral success message
- detail page shows reviewer/reviewed_at/note from the audit snapshot

For:

- already terminal request
- unsupported operation
- missing resource
- inconsistent resource state

do not show actionable controls.

Show a factual warning for inconsistent/missing resources if useful.

Do not expose automatic identity conclusions.

---

# Part H: Admin settings wording

Update the Follow Import policy hint from #149.

The page must accurately state:

- `always` is operational now and sends every Follow Import to moderator review
- `off` proceeds normally
- `high/medium/low` are reserved for automated review-signal integration and currently receive no automatic signal, so they do not hold imports yet

Keep all 5 choices visible because they are the intended final policy model.

Do not silently map high/medium/low to always/off.

---

# No automated classifier in this PR

DO NOT:

- call FollowImportRecurrenceObservationService for enforcement
- map containment/overlap to low/medium/high
- use historical action types as a live threshold
- change RiskEvaluationService
- change AdaptiveFollowGateDecisionService
- change ModeratorRecommendationService
- infer same person/sockpuppet/ban evasion
- automatically suspend/limit/warn an account
- auto-reject an import
- enable GLOBAL dispatch
- alter historical cohort semantics

Signal stays `none`.

---

# Tests

Add focused coverage for at least:

## Preflight

1. off + screening -> ready, no ActionReviewRequest
2. high + signal none -> ready, no request
3. medium + none -> ready, no request
4. low + none -> ready, no request
5. always + none -> pending ActionReviewRequest + review_required
6. request snapshot contains only allowed factual evidence
7. raw target addresses/hashes are not copied into evidence
8. retry reuses pending request
9. review_required retry stays held
10. stopped retry stays stopped
11. ready retry is not re-evaluated against changed site policy
12. failure while creating request/state rolls back and leaves non-executable screening

## Strict durable recording

13. active non-off policy + GLOBAL off + recorder failure => raises/retries, no direct bulk fallback
14. malformed policy (effective always) also forbids fallback
15. off + GLOBAL off preserves existing tolerant fallback
16. GLOBAL on remains strict regardless of Action Review policy

## Decision service/adapter

17. moderator/admin approve pending follow import
18. ordinary user forbidden
19. approve writes request reviewer/time/note
20. approve review_required -> ready + resume-required metadata
21. reject writes request rejected + reviewer/time/note
22. reject review_required -> stopped
23. approve does not create ModerationAction
24. reject does not create ModerationAction
25. repeated same decision idempotent
26. opposite terminal decision fails
27. concurrent decisions cannot both win
28. resource missing/mismatch/wrong state fails closed
29. unsupported operation has no decision adapter/action controls

## Resume

30. approved ready batch enqueues immediate resume worker
31. lost immediate enqueue does not undo durable approval
32. recovery scheduler finds unfinished approved resume
33. recovery scheduler ignores completed resume
34. resume worker validates approved follow-import request
35. resume worker on legacy owner re-hands off BatchExecutionWorker
36. scheduler owner is not converted to legacy
37. overwrite resume enqueues removals only after approval
38. resume success marks completed metadata
39. duplicate resume after completion is no-op
40. worker failure before completion leaves marker pending for retry

## CSV retention/cleanup

41. ready batch with review resume pending retains CSV even when no pending targets in legacy finalizer
42. same in GLOBAL DispatchExecutor finalizer
43. CSV cleanup scheduler retains review_required
44. retains screening
45. retains ready + resume pending
46. deletes stopped raw Import even with pending target rows
47. after resume completed + no pending, normal cleanup works

## User progress

48. review_required -> waiting-for-review label
49. stopped -> stopped label
50. stopped does not present active waiting work
51. normal ready/in-progress behavior unchanged
52. no moderation evidence/signal shown to user

## Admin UI

53. pending supported Follow Import shows approve/stop controls
54. terminal request shows no controls
55. unsupported operation shows no controls
56. approve/reject authorization is staff-only
57. stop has confirmation if implemented
58. decision note persists and renders escaped
59. browser-local reviewed_at remains correct

## Regression

60. #147 legacy/global ready fencing remains green
61. #148 Action Review foundation specs remain green
62. #149 queue/settings specs remain green
63. overwrite import normal off-policy path remains unchanged

---

# Operational semantics / comments

Document clearly:

- Action Review approval is an operation approval, not an account trust verdict
- rejection stops only this import
- current automatic signal is none
- threshold modes are not yet enforcement-active
- resume is at-least-once with durable recovery, not exactly-once
- CSV retention during resume pending is intentional
- stopped batches retain ledger rows but raw CSV is cleaned

---

# Migration

Prefer **no DB migration**.

Use existing FollowImportBatch `metadata` for resume-required/completed timestamps.

If implementation demonstrates a real need for a new column/index, stop and explain in completion report rather than casually expanding schema.

---

# Validation

Run focused specs for all touched components, including:

- Action Review services/model/policies/controllers
- ImportService
- FollowImport recorder/preflight/release
- BatchExecutionWorker
- DispatchExecutor
- CSV cleanup scheduler
- new resume worker/scheduler
- settings import progress helper/controller
- Action Review queue/settings controller specs

Run RuboCop on all changed Ruby/spec files.

No new lint tooling.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Connect Follow Import to Action Review`

PR body must explicitly state:

- first live Action Review operation
- `always` holds every Follow Import before behavior starts
- off/threshold-with-none proceeds normally
- low/medium/high automated classification is NOT implemented
- moderator approve -> ready + durable resume
- moderator stop -> stopped, no account moderation action
- overwrite removals are held too
- direct legacy fallback is disabled whenever Action Review policy is active
- resume has immediate worker + periodic recovery
- CSV retained until approved resume setup completes
- stopped CSV cleaned, ledger retained
- user progress shows waiting-for-review/stopped without exposing evidence
- no recurrence threshold / identity inference
- no DB migration

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head/base SHA
- exact changed files
- preflight state transitions
- exact policy truth table for this PR
- request evidence schema
- strict-fallback behavior
- decision adapter/state machine
- resume metadata keys
- resume worker + recovery scheduler behavior
- CSV retention/cleanup behavior
- user progress behavior
- exact routes/authorization
- exact RSpec results
- exact RuboCop result
- any deviation / unresolved race
