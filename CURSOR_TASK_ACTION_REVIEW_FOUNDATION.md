# Cursor task: generic Action Review foundation

## Context

We want a reusable, site-configurable human approval framework for operations that may need moderator review before execution.

Initial / planned operation families:

- Follow Import
  - has an automated detector / review signal
  - later may hold suspicious imports before any follow dispatch
  - some site admins may choose to require moderator approval for **every** Follow Import
- Account migration ("move")
  - no automatic detector required initially
  - some sites may require approval for every migration
- Invite code creation
  - no automatic detector required initially
  - some sites may require approval for every invite
- Future status/post data import
  - feature does not exist yet
  - should be able to use the same framework later

The architectural goal is NOT "Follow Import approval" as a one-off feature.

The goal is a generic **Action Review** layer:

1. operation-specific durable resource / execution barrier
2. optional automated review signal
3. site approval policy
4. generic pending review record / queue
5. moderator decision
6. operation-specific release / stop adapter

This PR implements only the generic persistence + policy foundation.

It MUST NOT yet block, approve, release, reject, or execute any real user operation.

## Branch / base

Work on:

`feature/action-review-foundation`

Base commit:

`83eee88df96c440acbaed2427a58cb4ab7a36fcf`

(#146 merged)

## Core design

Keep these concepts separate:

### 1. Automated review signal

The detector, if an operation has one, eventually returns one of:

- none
- low
- medium
- high

This is NOT an identity judgment, guilt score, abuse verdict, or moderation action.

For Follow Import, later signal evidence may include historical linked-negative recurrence, overlap counts, fingerprint completeness, etc.

### 2. Site intervention policy

The site decides how sensitive human intervention should be.

Five generic policy modes:

- `off` — never require review because of this policy
- `high` — require review for high signals
- `medium` — require review for medium/high signals
- `low` — require review for low/medium/high signals
- `always` — require review regardless of signal

This is "review intervention sensitivity", not a danger scale.

Operations without an automated detector initially support only the meaningful UI choices:

- off
- always

The backend registry may still share the same generic policy semantics.

### 3. Pending review request

A generic durable record captures:

- what operation is waiting
- who initiated it
- what durable resource represents it
- why review was requested
- what policy was active at that moment
- what signal/evidence existed at that moment
- eventual moderator decision metadata

The request is an audit snapshot. Later policy/evaluator changes must not rewrite historical review reasons.

## Suggested namespace / model

Use a generic model:

`ActionReviewRequest`

and services under:

`ActionReview::...`

Do not put the generic framework under `Moderation::`; some reviewed operations (e.g. invite creation) are administrative approval workflow, not necessarily moderation evidence.

Naming deviations are fine if they fit repository conventions, but preserve the separation.

## Operation registry

Add a small registry / catalog, e.g.:

`ActionReview::OperationRegistry`

Initially register semantic operation keys for:

- `follow_import`
- `account_migration`
- `invite_creation`
- `status_import` (reserved for future use; no integration)

For each operation expose factual capability metadata, at minimum:

- operation key
- whether automated signals are supported

Example concept:

```ruby
{
  'follow_import'      => { automated_signal: true },
  'account_migration'  => { automated_signal: false },
  'invite_creation'    => { automated_signal: false },
  'status_import'      => { automated_signal: false },
}
```

Do not add behavior adapters in this PR.

Unknown operation keys should fail explicitly rather than silently becoming "off".

## Site policy storage

Add a global site setting shape for Action Review policies.

Prefer a scalable hash setting in `config/settings.yml`, e.g.:

```yaml
action_review_policies:
  follow_import: off
  account_migration: off
  invite_creation: off
  status_import: off
```

All defaults MUST be `off` so this PR changes no current behavior.

Do not add Admin UI in this PR.

Add a small settings reader / policy resolver that:

- reads the configured mode for a registered operation
- validates/normalizes against `off high medium low always`
- exposes supported modes for UI later
- does not silently accept an unknown operation
- has deterministic behavior for malformed/missing configuration

Choose a conservative malformed-config behavior and document it clearly.

Important:
- default installation behavior stays off
- do not hard-code Follow Import policy outside the registry/settings layer

## Policy decision service

Add a pure/read-only service, e.g.:

`ActionReview::PolicyDecisionService`

Suggested API:

```ruby
result = service.call(
  operation_type: 'follow_import',
  signal_level: 'medium',
  evaluation_status: 'ok'
)
```

It should read site policy by default but allow injected/explicit policy mode in specs if useful.

Return a stable factual structure, suggested:

```text
operation_type
policy_mode
signal_level
evaluation_status
requires_review
trigger
policy_version
reason_codes
```

Suggested policy version string:
`action-review-policy-v1`

### Required threshold semantics

With evaluation_status = ok:

- off:
  - none/low/medium/high -> no review
- high:
  - high -> review
  - none/low/medium -> no review
- medium:
  - medium/high -> review
- low:
  - low/medium/high -> review
- always:
  - all signal levels -> review

### Evaluation errors

We explicitly want future enforcement to fail toward HUMAN REVIEW rather than silently bypassing configured intervention.

Semantics:

- policy `off` + evaluator error:
  - no review required by Action Review policy
- policy `always`:
  - review regardless
- threshold policy `low/medium/high` + evaluator error:
  - require review
  - trigger should clearly indicate evaluator failure / unavailable evaluation
  - this is NOT an automatic reject

This creates a safe future path:
evaluation failure -> moderator queue -> moderator can release.

Do not throw a user-visible moderation decision from an evaluator error.

### Operation without detector

For an operation whose registry says automated_signal = false:

- ordinary call should use signal_level = none
- off => no review
- always => review

Expose supported policy modes so future Admin UI can show only off/always.

Do not invent automatic signals for those operations.

## ActionReviewRequest schema

Create a migration and model.

Suggested fields (adjust names to repository style if needed):

```text
id
operation_type        string, not null
state                 integer/string, not null
actor_account_id      bigint, nullable
resource_type         string, not null
resource_id           bigint, not null

trigger                string, not null
signal_level           string, not null
policy_mode            string, not null
policy_version         string, not null
evaluator_version      string, nullable

reason_codes           jsonb, default [], not null
evidence               jsonb, default {}, not null

requested_at           datetime, not null
reviewed_at            datetime, nullable
reviewer_account_id    bigint, nullable
decision_note          text, nullable

created_at
updated_at
```

Optional `lock_version` is reasonable if useful for later concurrent decisions.

### State semantics

Define only generic review states:

- pending
- approved
- rejected
- cancelled

No "safe", "dangerous", "abusive", etc.

This PR does not implement operation release/stop side effects.

### Associations / deletion durability

The review record is audit data.

- actor account may later disappear
- reviewer account may later disappear
- the operation resource may later disappear

Do not design deletion behavior that causes account/resource deletion to fail because an ActionReviewRequest exists.

Prefer nullable actor/reviewer references with appropriate FK nullification if consistent with this repo.

Polymorphic resource references cannot have a normal FK; do not fabricate one.

Historical request rows should remain readable even if associations vanish.

### Validation

Validate at least:

- registered operation_type
- valid state
- valid signal_level: none/low/medium/high
- valid policy_mode: off/high/medium/low/always
- trigger presence
- policy_version presence
- requested_at presence
- resource_type/resource_id presence
- reason_codes is an array-like JSON shape
- evidence is object/hash-like JSON shape

Do not require reviewer/reviewed_at while pending.

### Active duplicate protection

Prevent duplicate *pending* requests for the same logical operation resource.

Prefer a PostgreSQL partial unique index for:

`operation_type + resource_type + resource_id`

where state is pending.

This should still allow historical approved/rejected/cancelled rows if the same resource legitimately receives another review later.

Add a matching model-level validation if useful, but DB uniqueness is authoritative.

## Request creation service

Add a small idempotent service, e.g.:

`ActionReview::RequestService`

It receives:

- operation_type
- actor_account
- resource
- policy decision
- evaluator_version
- evidence

It should:

- create a pending ActionReviewRequest only when `requires_review == true`
- return a stable result when review is not required
- snapshot policy_mode / signal_level / trigger / policy_version / reason_codes
- snapshot only passed factual evidence
- avoid duplicate pending request under retry / concurrency
- never mutate or execute the underlying resource
- never change account moderation state
- never notify in this PR

Do not make it infer evidence from Follow Import yet.

The caller owns evidence construction.

If concurrent creation hits the unique index, return the existing pending request deterministically.

## Privacy / evidence boundary

The generic request may store structured factual evidence, but this PR should not introduce content payloads.

Do not store:

- post bodies
- DMs
- profile text
- ActivityPub payloads
- raw Follow Import target lists
- raw email/IP secrets

For future Follow Import evidence, aggregated IDs/counts/reason codes can be passed later.

The model should not know Follow Import-specific fields.

## No decision side effects yet

Do NOT implement in this PR:

- approve endpoint
- reject endpoint
- release adapter
- stop adapter
- admin queue
- navigation badge
- email/notification
- Follow Import integration
- account migration integration
- invite integration
- status import integration
- automatic recurrence classifier
- thresholds mapping containment to low/medium/high
- RiskEvaluation change
- Follow Gate change
- moderation action creation

This is deliberately the generic foundation only.

## Admin settings UI is next PR

Do not modify `Form::AdminSettings` or `admin/settings/edit` unless strictly required for the setting to load.

A dedicated Action Review policy page will be cleaner because the existing admin settings page is already large.

This PR should only establish settings storage/reader semantics.

## Specs

Add focused specs covering at least:

### Registry

1. known operations resolve
2. follow_import reports automated signal support
3. account_migration / invite_creation / status_import do not
4. unknown operation fails explicitly
5. supported policy modes:
   - follow_import -> off/high/medium/low/always
   - detectorless operations -> off/always

### Policy decision

6. off never reviews for none/low/medium/high
7. high only reviews high
8. medium reviews medium/high
9. low reviews low/medium/high
10. always reviews all
11. threshold mode + evaluation error => review
12. off + evaluation error => no review
13. always + evaluation error => review
14. detectorless op + none + off => no review
15. detectorless op + none + always => review
16. result contains policy version + factual trigger/reason codes
17. no score / guilt / identity semantics

### Settings reader

18. default policy is off for all registered operations
19. configured valid policy is read correctly
20. missing hash key falls back deterministically
21. malformed mode follows the documented conservative behavior
22. unknown operation is not silently accepted

### Model

23. pending request valid with factual snapshot fields
24. reviewer/reviewed_at optional while pending
25. invalid operation rejected
26. invalid signal rejected
27. invalid policy rejected
28. evidence must be hash/object
29. reason_codes must be array
30. actor/reviewer may be nil
31. polymorphic resource resolves when present
32. request survives nullable actor/reviewer association disappearance semantics
33. partial unique pending index prevents duplicate active review for same operation/resource
34. a later historical review row is allowed after prior request is no longer pending

### Request service

35. requires_review=false creates nothing
36. requires_review=true creates one pending row
37. snapshots exact decision fields
38. snapshots evaluator version/evidence
39. repeated call returns same pending request / does not duplicate
40. concurrent/RecordNotUnique fallback resolves existing pending row
41. writes no underlying resource changes
42. no notifications or moderation actions

## Migration / schema

Use a new timestamp greater than current schema version `2026_09_21_050001`.

Regenerate `db/schema.rb`.

Keep indexes explicit and named clearly.

## Validation commands

Run focused specs for all new files.

Also run enough existing settings/model specs to prove the new default hash does not disturb Setting initialization.

Run RuboCop on all changed Ruby/spec files.

No new lint tooling.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add generic Action Review policy and request foundation`

PR body must explicitly state:

- generic human-approval foundation, not Follow Import-specific
- registered planned operations
- five intervention modes
- detectorless operations effectively use off/always
- evaluator errors under active threshold policy route toward review, not automatic rejection
- defaults are all off, so behavior does not change
- ActionReviewRequest is audit snapshot + generic resource reference
- no queue UI / no notifications / no operation integration / no enforcement in this PR
- no identity inference or risk scoring

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head SHA / base SHA
- exact changed files
- migration/schema fields and indexes
- operation registry contents
- supported policy modes per operation
- exact policy truth table
- malformed-setting behavior
- evaluator-error behavior
- ActionReviewRequest state machine
- request-service idempotency behavior
- exact RSpec results
- exact RuboCop result
- any design deviation / unresolved concern
