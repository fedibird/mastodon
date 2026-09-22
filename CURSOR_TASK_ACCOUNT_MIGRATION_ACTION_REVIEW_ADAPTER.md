# Cursor task: connect Account Migration to Action Review with moderator metrics UI

## Context / product intent

Merged foundations:

- #148 generic Action Review policy/request foundation
- #149 Action Review queue/settings
- #150 Follow Import live adapter
- #151 Follow Import shadow review-signal classifier
- #152 Invite creation live adapter + generic adapter-driven controls

`account_migration` is already registered in `ActionReview::OperationRegistry` as a detectorless operation, so supported policy modes remain exactly:

- `off`
- `always`

This feature is intentionally exceptional.

Account migration is a fundamental Fediverse exit / portability mechanism. Users may legitimately leave because they dislike the server, want to self-host, or simply want to move. The default must remain immediate and unchanged.

The site may choose `always` only when operators want human review before follower transfer / Move execution, for example to inspect unusual follower-acquisition patterns. The UI must present factual behavioral metrics and let a moderator decide; it must NOT label an account as malicious, laundering, abusive, fraudulent, sockpuppet, or the same person as another account.

Do not add an automatic account-migration classifier in this PR.

## Branch / base

Work on:

`feature/account-migration-action-review-adapter`

Base:

`75d8d4bdc4dc552ba65686195e8388fffa170e89`

(#152 merged)

---

# Core behavior

Truth table:

```text
account_migration: off
  -> existing password/username challenge
  -> persist AccountMigration
  -> MoveService runs immediately as before
  -> no ActionReviewRequest

account_migration: always
  -> existing password/username challenge
  -> validate and persist AccountMigration
  -> create pending ActionReviewRequest
  -> DO NOT call MoveService
  -> source account is NOT redirected yet
  -> follower transfer / Move / Update distribution are NOT enqueued yet
  -> moderator decision:
       approve -> durable execution worker -> MoveService
       reject  -> no MoveService; request remains historical audit row
```

Redirect-only functionality under `Settings::Migration::RedirectsController` is OUT OF SCOPE and must remain unchanged. The moderation concern here is follower-transfer migration, not the user's ability to publish a simple redirect.

---

# Part A: Account Migration creation service

Do not put Action Review policy branching directly into `Settings::MigrationsController`.

Add a dedicated service, suggested:

`AccountMigration::CreateService`

or a similarly clear namespace.

Input:

- source account
- current user
- migration attributes

Return a small Result object with at least:

- migration
- request
- status

Suggested statuses:

- `:moved`
- `:pending_review`
- `:invalid`

## Existing challenge must stay authoritative

Preserve `AccountMigration#save_with_challenge(current_user)` behavior:

- password-backed users must provide correct current password
- passwordless users must provide current username
- target resolution / alsoKnownAs validation stays in the existing model
- existing cooldown validation stays part of persistence

Do NOT weaken or bypass the challenge because a moderator will later approve.

## Policy evaluation

Use:

```ruby
ActionReview::PolicyDecisionService.new.call(
  operation_type: 'account_migration',
  signal_level: 'none',
  evaluation_status: 'ok'
)
```

No automated detector.

## off path

Preserve current behavior as closely as possible:

1. save_with_challenge
2. if valid, `MoveService.new.call(migration)`
3. return moved
4. no ActionReviewRequest

## always path

The AccountMigration row is the Action Review resource.

Create AccountMigration + pending request atomically:

```text
transaction
  save_with_challenge(current_user)
  create ActionReviewRequest(resource: migration)
commit
```

If review persistence fails, roll back the AccountMigration row.

Do not call MoveService in this path.

The migration row is allowed to exist before execution; the source account remains unmoved until approval.

---

# Part B: cooldown semantics

Today `AccountMigration.within_cooldown` treats every recent AccountMigration row as a 30-day cooldown.

That would unfairly make a rejected/cancelled moderation review block legitimate retry for 30 days.

Change cooldown semantics:

- ordinary/off-path migration within 30d -> cooldown
- pending account-migration review -> cooldown
- approved account-migration review -> cooldown
- rejected account-migration review -> NOT cooldown
- cancelled account-migration review -> NOT cooldown

This preserves:
- no duplicate migration submissions while one is waiting
- normal 30-day cooldown after a real/approved migration
- immediate ability to submit a different legitimate migration after moderator stop/cancel

Implement with an ActionReviewRequest subquery if practical; do not add a duplicated review-state column just for cooldown.

Add specs.

---

# Part C: factual migration review metrics

The user/operator intent is that moderators can inspect behavioral metrics before deciding.

Add a read-only service, suggested:

`AccountMigration::ReviewMetricsService`

No scoring. No recommendation. No enforcement. No identity inference.

Use a fixed `as_of` argument.

Suggested windows:

- 1h
- 24h
- 7d

## Reuse existing moderation ledger

Compose `Moderation::BehavioralMetricsService` rather than reimplementing rejection qualification.

For each window expose factual fields useful to review:

- contacts_total
- unique_targets
- follows
- unique_follow_targets
- qualified_negative_events
- qualified_unique_negative_responders
- follow_rejects_received
- blocks_received
- reports_received
- qualified_negative_response_rate
- follow_reject_rate
- new_targets_after_first_negative_signal
- follows_after_first_negative_signal

Also expose existing aggregate Follow Import context:

- batch_count
- target_total
- resolved_target_total
- unresolved_target_total
- unresolved_target_ratio
- prior_relationship_known_targets
- latest_import_at

No raw target IDs or lists.

## Add returned-follow metrics

Add read-only counts specifically useful for the migration review scenario.

### Returned follow after observed outgoing follow

For each window:

- `returned_follows_after_outgoing`
- `returned_follow_rate`

Definition:

A returned follow is an incoming `Follow` to the source account from an account that the source had previously followed/attempted to follow in the same observation window, with incoming Follow.created_at >= the observed outgoing follow time and <= as_of.

Prefer the moderation interaction ledger for the outgoing-follow timestamp so an outgoing follow that was later removed can still be observed.

Map target ModerationSubject -> Account only when account_id is still available.

Deduplicate by counterpart account.

`returned_follow_rate = returned / unique observable outgoing follow targets`.

This is a temporal association only. It is NOT proof that the follow caused the return follow.

### Follow Import returned follow

For each window expose:

- `follow_import_batches`
- `follow_import_unique_resolved_targets`
- `follow_import_returned_follows`
- `follow_import_returned_follow_rate`

Definition:

For FollowImportBatch rows belonging to the source ModerationSubject and imported within the window, find unique resolved target accounts. Count a returned follow only when that target account follows the source account at/after the relevant import time and <= as_of.

If a target appears in multiple batches, use a deterministic earliest relevant import timestamp within the window.

No unresolved target inference through target_key_hash.

No account/subject/target ID arrays in the result.

### Basic account snapshot

Also include factual source-account snapshot:

- generated_at/as_of
- account_age_seconds
- followers_count
- following_count
- statuses_count

Rates are raw floats; presentation may round.

## Privacy

Do NOT put in the metrics payload:

- email
- IP
- target account ids
- ModerationSubject ids
- raw account address lists
- target_key_hash arrays
- post/profile/report bodies
- DMs
- ActivityPub payload bodies

---

# Part D: Action Review request evidence

When `always` creates the pending request, snapshot the metrics at request time.

Suggested evidence schema:

```json
{
  "schema_version": 1,
  "target_acct": "user@example.org",
  "followers_count_at_request": 1234,
  "target_account_local": false,
  "metrics": {
    "...": "privacy-minimized ReviewMetricsService output"
  }
}
```

The resource already identifies AccountMigration; actor_account identifies the source account.

Do not store password/current_username challenge values.

Do not store target account profile text.

Use `requested_at` / metrics `as_of` consistently so the snapshot is causal at the migration request time.

---

# Part E: Account Migration decision adapter

Add:

`ActionReview::Adapters::AccountMigration`

Register it in `ActionReview::AdapterRegistry`.

Implement `.actionable?(request)` for the generic UI.

## Read-only actionable checks

For a pending request:

- operation_type == account_migration
- resource_type == AccountMigration
- resource exists / id matches
- actor_account matches migration.account
- source account exists
- target_account exists
- source account is local
- source account is not suspended
- source is not already moved to a different target
- target is not source
- cached target alsoKnownAs still contains the source URI
- evidence schema recognized

Do not do network fetches inside `.actionable?`.

If the cached target changed/staled, fail closed and show inconsistent-resource warning.

## Approve

Use deterministic lock order:

1. AccountMigration resource
2. ActionReviewRequest

Revalidate the same critical conditions under lock.

Atomically:

- request pending -> approved
- reviewer/reviewed_at/decision_note
- leave MoveService execution to the durable worker below

Do NOT call MoveService inside the DB transaction.

Do NOT create ModerationAction.

## Reject

Atomically:

- request -> rejected
- reviewer/reviewed_at/note
- no MoveService
- source remains unmoved
- no ModerationAction

## Idempotency

- repeated approve on approved -> harmless `:already_approved`
- repeated reject on rejected -> harmless `:already_rejected`
- opposite terminal decision -> DecisionError
- cancelled is terminal/non-actionable
- concurrent moderators: exactly one terminal decision wins

---

# Part F: durable post-approval migration execution

Approval must not depend on one best-effort Sidekiq enqueue.

Add a migration to `account_migrations`:

```ruby
add_column :account_migrations, :action_review_executed_at, :datetime
```

Nullable, no backfill required.

This field is ONLY for reviewed migration execution completion.

Existing/off-path migrations may leave it nil because they do not have an approved ActionReviewRequest.

Add schema annotation.

## Immediate worker

Suggested:

`AccountMigration::ActionReviewExecutionWorker`

Input: ActionReviewRequest id.

Worker validates:

- request exists
- operation_type account_migration
- request approved
- resource AccountMigration exists
- request/resource/actor relation matches
- migration.action_review_executed_at is nil
- source not moved to a different target
- critical target/backreference checks still hold

Use the AccountMigration Redis lock, e.g. a dedicated:

`account_migration_action_review:<migration.id>`

Recheck after lock acquisition.

Then:

1. `MoveService.new.call(migration)`
2. on successful return, persist `action_review_executed_at = Time.now.utc`

Worker retry budget may be small/normal (e.g. 5).

If MoveService raises, do not stamp completed.

## Recovery scheduler

Add bounded scheduler every ~5 minutes:

`Scheduler::AccountMigrationActionReviewExecutionScheduler`

Select approved ActionReviewRequest rows:

- operation_type account_migration
- resource_type AccountMigration
- AccountMigration.action_review_executed_at IS NULL

Bound pass (e.g. 100/500; migrations are rare).

Enqueue execution worker.

This recovers lost immediate enqueue.

Add to `config/sidekiq.yml`.

## At-least-once semantics

There is an unavoidable enqueue/DB marker gap.

Document:

- execution is at-least-once
- ActivityPub Move serializer ID is deterministic from migration id
- repeated delivery of the same Move activity is preferable to losing the migration
- MoveWorker path must be safe enough to repeat

### Fix existing MoveWorker visible duplication

`MoveWorker#copy_account_notes!` currently appends the copied-note preface/source note again when the same MoveWorker runs twice.

Make this path idempotent.

Use the deterministic localized `move_handler.copy_account_note_text` marker for the source acct.

If the target note already contains the migration-copy marker for that source account, do not prepend/append the copied source note again.

Do not destroy or overwrite pre-existing target note text.

Add a regression spec that running MoveWorker twice does not duplicate the copied-note section.

Review other MoveWorker substeps; avoid broad behavior changes unless a repeat-visible duplication is demonstrated.

---

# Part G: Settings::MigrationsController + user UI

Use AccountMigration::CreateService.

## create

- `:moved`
  - preserve existing moved success redirect/message
- `:pending_review`
  - redirect to settings_migration_path
  - neutral notice:
    "Your account migration is waiting for moderator approval. No follower transfer or redirect has started yet."
- `:invalid`
  - render existing form with errors

Do not say the account is suspicious.

## show/history

Add a one-query review lookup for displayed migrations, similar to InviteCreation::ReviewLookup.

Suggested:

`AccountMigration::ReviewLookup.for_migrations(@migrations)`

For each migration row show workflow state:

- no review -> moved / existing behavior
- pending -> Waiting for approval
- approved + executed_at nil -> Approved, processing
- approved + executed_at present -> Moved
- rejected -> Stopped
- cancelled -> Cancelled/Stopped

Pending/approved-not-executed migration should keep the form disabled through cooldown.

Rejected/cancelled should no longer keep cooldown.

Do not expose moderator notes/reasons to the user.

Do not add requester cancel in this PR.

---

# Part H: Admin Action Review migration detail

Add an operation-specific partial:

`app/views/admin/action_reviews/_account_migration.html.haml`

Display factual information:

## Migration facts

- source account
- target account / target acct
- followers_count captured by AccountMigration
- request timestamp
- target local/remote
- source current moved status
- execution status:
  - waiting for review
  - approved / processing
  - executed
  - stopped
  - cancelled

Do not print challenge data.

## Request-time metrics snapshot

Human-readable table for 1h / 24h / 7d:

- outgoing follows
- unique outgoing targets
- incoming returned follows
- returned-follow rate
- Follow Import batches
- Follow Import unique resolved targets
- Follow Import returned follows
- Follow Import returned-follow rate
- qualified negative responders/events
- follow rejects
- blocks
- reports
- new targets after first qualified negative
- follows after first qualified negative

Also show:
- follower/following/status counts at request
- account age
- latest Follow Import time
- Follow Import target totals / unresolved count

Use neutral labels.

Add a visible explanatory hint:

- returned-follow metrics are timing associations, not proof of manipulation
- Follow Import followback metrics do not establish identity or intent
- account migration itself is a normal Fediverse portability feature

## Current metrics while pending

For a pending account_migration review with a still-present source account, compute a fresh `ReviewMetricsService` snapshot in the show action/helper and render a second "Current observation" block.

This lets moderators see activity that continued after the request.

Label:
- request-time snapshot
- current observation
- generated_at/browser-local time

Do not persist the current snapshot into ActionReviewRequest.

For terminal requests, request-time snapshot alone is sufficient; current snapshot is optional, but do not let post-decision activity rewrite historical evidence.

## Controls

Generic adapter-driven approve/stop controls should appear for actionable pending migration request.

Use operation-specific text:

Approve button:
- "Approve migration" / Japanese equivalent
not "Approve and run" if cleanly supported by helper.

Stop confirmation:
- explicitly says only this migration request is stopped; it does not suspend/limit the account.

Flash:
- approved: migration approved and queued for execution
- stopped: migration request stopped

Do not create account moderation action.

---

# Part I: Action Review settings copy

Update account_migration help text.

English intent:

- off: migration executes immediately after the normal account challenge
- always: follower transfer / Move waits for staff approval
- migration is a normal portability mechanism; this setting is for sites that require human review before follower transfer
- behavioral metrics are factual context, not an automatic abuse verdict

Japanese equivalent.

Still only off/always.

Invite + Follow Import wording must stay accurate.

status_import remains unintegrated.

---

# Part J: Admin account navigation convenience

If clean and small, add a link from the account-migration Action Review detail to the existing admin account page for the source account and target account.

Do not create a separate migration-admin controller.

The canonical queue remains Action Review.

---

# Part K: tests

Add focused coverage for at least:

## Create service / controller

1. off -> existing migration saved + MoveService called + no review
2. always -> migration + pending request, MoveService NOT called
3. challenge failure -> no migration/review
4. model validation failure -> no review
5. review persistence failure rolls back migration
6. request signal_level remains none
7. Redirect-only controller unchanged
8. pending notice says no move has started
9. ordinary moved notice remains on off path

## Cooldown

10. ordinary recent migration counts as cooldown
11. pending reviewed migration counts
12. approved reviewed migration counts
13. rejected reviewed migration does not count
14. cancelled reviewed migration does not count
15. direct POST while pending still fails cooldown validation

## Metrics service

16. account snapshot counts
17. fixed as_of excludes later follow rows/events
18. returned follow only when incoming follow occurs after observed outgoing follow
19. incoming-before-outgoing does not count
20. dedupe counterpart accounts
21. returned rate denominator is observable unique outgoing targets
22. Follow Import returned follow only after batch imported_at
23. unresolved FollowImportTarget never inferred via hash
24. target in multiple batches deterministic/unique
25. negative metrics compose BehavioralMetricsService
26. payload has no raw ids/hash/address arrays/content
27. empty subject/data returns zeros

## Request evidence

28. evidence schema contains target acct/follower count/metrics
29. no password/current_username
30. no email/IP/raw target ids
31. metrics as_of matches request time

## Adapter

32. registry includes account_migration
33. actionable valid pending migration
34. mismatched actor false/fails closed
35. missing migration false
36. suspended source false
37. moved-to-different-target false
38. target missing backreference false
39. approve -> request approved, no MoveService inside transaction
40. reject -> request rejected, source unmoved
41. no ModerationAction
42. repeated approve idempotent
43. repeated reject idempotent
44. opposite terminal decision fails
45. concurrent decisions exactly one winner
46. cancelled no controls

## Execution

47. approve enqueues execution worker after commit
48. lost enqueue does not change durable approved state
49. scheduler picks approved unexecuted migration
50. scheduler ignores executed migration
51. worker validates approved request/resource
52. worker calls MoveService once under lock and stamps executed_at
53. duplicate worker after executed_at is no-op
54. MoveService failure leaves executed_at nil for retry
55. source moved to different target fails closed
56. bounded scheduler

## MoveWorker repeat safety

57. running MoveWorker copy-account-note path twice does not duplicate migration-copy marker/source note
58. pre-existing target note content remains

## User migration UI

59. pending row says waiting
60. approved unexecuted says processing
61. executed says moved
62. rejected/cancelled says stopped
63. rejected/cancelled allow a new migration (cooldown removed)
64. no moderator note/evidence exposed

## Admin UI

65. pending migration shows approve/stop
66. detail shows source + target
67. request-time metrics readable
68. pending detail shows current metrics
69. metrics labels/caveat are neutral
70. no password/challenge data
71. no raw target IDs/hashes
72. terminal row no controls
73. missing/inconsistent resource warning
74. source/target admin links where available
75. browser-local generated/review timestamps

## Settings

76. account_migration exposes only off/always
77. help copy states adapter is live and migration is normal portability
78. status_import remains unintegrated

## Regression

79. Follow Import adapter controls/decision specs remain green
80. Invite adapter controls/list safety remains green
81. generic DecisionService remains green
82. Action Review queue/settings remain green

---

# Migration / schema

This PR IS allowed one small migration:

`account_migrations.action_review_executed_at :datetime, null: true`

No enum/state duplication needed; ActionReviewRequest is the review state source.

Update schema annotation.

Do not add risk columns or scores.

---

# Validation

Run focused specs for:

- AccountMigration model/controller/view
- new CreateService
- new ReviewMetricsService
- AccountMigration adapter
- execution worker + recovery scheduler
- MoveWorker idempotence regression
- Admin ActionReviews controller/helper/view
- Action Review settings
- Follow Import adapter regression
- Invite adapter regression

Run RuboCop on every changed Ruby/spec file.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Connect Account Migration to Action Review`

PR body must explicitly state:

- account migration remains a normal portability/exit feature
- default/off path is unchanged and immediate
- always is human review only; no automatic classifier
- redirect-only migration remains unchanged
- migration row is persisted but MoveService is not called before approval
- rejected/cancelled reviews do not impose the 30-day cooldown
- moderator UI shows factual request-time behavioral metrics
- pending review additionally shows current observation
- returned-follow/follow-import-return metrics are temporal associations, not proof of abuse
- approval queues durable execution
- recovery scheduler exists
- execution is at-least-once
- MoveWorker note-copy repeat safety was fixed if needed
- no ModerationAction
- exact migration/schema change
- exact RSpec/RuboCop results

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR number/URL
- head/base SHA
- exact changed files
- create service result semantics
- cooldown semantics
- exact evidence schema
- exact metrics schema/definitions
- adapter actionable checks
- approve/reject state machine
- execution worker + scheduler behavior
- action_review_executed_at semantics
- MoveWorker repeat-safety change
- user migration UI changes
- admin Action Review UI changes
- settings copy changes
- exact RSpec result
- exact RuboCop result
- any deviation / unresolved race
