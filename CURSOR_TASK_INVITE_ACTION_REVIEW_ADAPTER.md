# Cursor task: connect Invite creation to Action Review and admin UI

## Context

Merged foundations:

- #148 generic Action Review policy/request foundation
- #149 Action Review queue + settings UI
- #150 first live Follow Import adapter + approve/stop flow
- #151 Follow Import shadow classifier (not relevant to Invite enforcement)

`invite_creation` is already registered in `ActionReview::OperationRegistry` as a detectorless operation, so its supported policy modes are intentionally only:

- `off`
- `always`

Now make Invite issuance the second live Action Review operation.

## Branch / base

Work on:

`feature/invite-action-review-adapter`

Base:

`f88a4fb76eb6d0293623293c9fcf7dea4d4e4e63`

(#151 merged)

## Core invariant

When Invite policy is `always`, there must NEVER be a usable invite code before moderator approval.

Existing `Invite#valid_for_use?` remains the registration boundary:

```ruby
(max_uses.nil? || uses < max_uses) && !expired? && user&.functional?
```

Use this existing contract rather than inventing a second registration bypass.

No identity/risk classifier for invites in this PR.

---

# Part A: create an inactive pending Invite shell

Use the actual persisted `Invite` row as the Action Review resource.

Do NOT use User/Account as the resource; the pending unique index would incorrectly allow only one pending invite per actor.

Do NOT create an active Invite and then try to hide it only in the UI.

## Pending shell

When `invite_creation: always`:

1. build the Invite with the requested normal attributes
2. remember the requested expiration duration
3. before saving, force `expires_at` to a time safely in the past
4. save the Invite
5. create the pending ActionReviewRequest with resource = that Invite
6. commit both in one DB transaction

The resulting invite MUST fail `valid_for_use?`.

Suggested inactive sentinel:

```ruby
invite.expires_at = Time.now.utc - 1.second
```

Do not use a secret alternate registration path.

The generated code may exist in DB, but pending/rejected management UI must not expose/copy the public invite URL.

## Why expires_at

This requires no schema migration and makes all existing registration paths fail closed because `Auth::RegistrationsController#set_invite` already accepts only `valid_for_use?` invites.

`Invite.available` will also exclude the pending shell.

## Requested expiration

The pending shell overwrites `expires_at`, so persist the originally requested expiration duration in the Action Review evidence.

Normalize using existing Invite/Expireable semantics.

Suggested evidence:

```json
{
  "schema_version": 1,
  "requested_max_uses": 10,
  "requested_expires_in_seconds": 86400,
  "autofollow": false,
  "comment_present": false
}
```

For no expiration, `requested_expires_in_seconds` is null.

Do NOT include:

- invite code
- public invite URL
- email/IP
- arbitrary comment text
- account/profile text

`comment_present` is enough for audit context; the actual comment remains on Invite if one was supplied.

The actor is already captured by `actor_account_id`.

---

# Part B: Invite creation service used by BOTH controllers

Do not duplicate policy logic in:

- `InvitesController#create`
- `Admin::InvitesController#create`

Add a dedicated service, suggested:

`InviteCreation::CreateService`

or another clearly scoped name.

It should:

- accept issuing `user`
- accept the existing permitted invite attributes
- build the Invite
- evaluate:
  ```ruby
  ActionReview::PolicyDecisionService.new.call(
    operation_type: 'invite_creation',
    signal_level: 'none',
    evaluation_status: 'ok'
  )
  ```
- if no review required:
  - preserve current behavior: normal Invite save, immediately usable according to existing fields
  - create NO ActionReviewRequest
- if review required:
  - create inactive shell + ActionReviewRequest atomically
- return a small Result object that lets controllers distinguish:
  - validation failure
  - immediately issued
  - pending review

Preserve validation errors on the Invite so existing forms can re-render naturally.

If ActionReview persistence fails after the shell save, roll back the Invite transaction. Never leave an orphan pending shell without its review request.

Malformed settings already resolve conservatively through PolicySettings; do not bypass that.

## Controller behavior

Both current invite creation surfaces must use the service:

- user/staff `/invites`
- admin `/admin/invites`

On immediate issuance: preserve existing redirect behavior.

On pending review:
- redirect back to the same invite list
- show neutral notice such as "Invite creation is waiting for moderator approval"
- do not show/copy the code

On validation failure:
- render the same form/list with errors as today

Do not change InvitePolicy role rules in this PR.

---

# Part C: Invite Action Review adapter

Add:

`ActionReview::Adapters::InviteCreation`

Register it in:

`ActionReview::AdapterRegistry`

The generic Admin::ActionReviewsController already has approve/reject routes. Reuse them.

## Source validation

Before a first decision, fail closed unless all are true:

- request.operation_type == `invite_creation`
- request.resource_type == `Invite`
- resource exists and matches resource_id
- request is pending
- Invite has not already been used (`uses == 0`)
- Invite is currently unusable/expired as the pending shell
- evidence schema is recognized
- evidence contains a valid `requested_expires_in_seconds` value or null
- actor/resource relationship is consistent where practical:
  - Invite.user.account should correspond to request.actor_account

Do not infer anything about the actor.

## Approve

In one DB transaction with deterministic lock order:

- lock Invite
- lock/reload ActionReviewRequest
- set request -> approved
- reviewer_account_id / reviewed_at / decision_note
- activate Invite by restoring requested expiration:
  - null requested duration -> `expires_at = nil`
  - numeric duration -> `expires_at = now + duration.seconds`
- do NOT change max_uses/autofollow/comment other than what the original request already stored on Invite
- create no ModerationAction

Once the transaction commits, normal `valid_for_use?` determines usability.

If the issuing user later becomes non-functional, the existing valid_for_use? rule naturally keeps the code unusable. Action Review approval must not override account state.

## Reject / Stop

Atomically:

- request -> rejected
- reviewer/time/note
- Invite remains expired/inactive

Do not delete the Invite row. It is the durable audit resource.

Do not create a ModerationAction.

## Idempotency

Important: an approved invite may later expire or exhaust max_uses.

Therefore repeated approve MUST NOT reactivate it.

Rules:

- request already approved + same approve -> `:already_approved`, no Invite mutation
- request already rejected + same reject -> `:already_rejected`, no Invite mutation
- opposite decision after terminal state -> DecisionError
- concurrent moderators -> exactly one terminal decision
- stale page submission cannot flip decision

Do NOT make idempotency depend on current `invite.valid_for_use?`, because a legitimately approved invite can later expire.

---

# Part D: generalize Action Review decision-control UI

Current `Admin::ActionReviewHelper#action_review_decision_controls?` is hard-coded to FollowImportBatch.

Refactor this into the adapter contract rather than adding another growing case statement.

Suggested design:

Each decision adapter exposes a read-only class predicate:

```ruby
def self.actionable?(request)
  ...
end
```

Then AdapterRegistry can expose:

```ruby
ActionReview::AdapterRegistry.actionable?(request)
```

Behavior:

- unknown adapter -> false
- missing resource -> false
- malformed state -> false
- never mutates

Update the existing FollowImport adapter to implement the predicate with the same semantics currently hard-coded in the helper.

Then the helper becomes generic:

- pending + registered + adapter actionable -> show approve/stop controls
- pending + registered but inconsistent/missing -> show neutral inconsistent-resource warning
- unsupported operation -> no controls

Do not regress Follow Import controls.

---

# Part E: Action Review detail for Invite creation

On the Action Review detail page, add a human-readable Invite creation section when operation is `invite_creation`.

Display factual fields:

- issuing account
- requested max uses (unlimited if nil)
- requested lifetime (no expiry if nil; otherwise duration)
- autofollow yes/no
- whether a comment was present
- current Invite workflow status:
  - waiting for review
  - approved
  - stopped
- current uses count

Do NOT display the invite code or public URL while request is pending or rejected.

For an approved request it is acceptable to link the moderator to the normal Admin Invites list, but do not duplicate/copy the invite URL into Action Review evidence/detail.

Keep the raw audit JSON section as today; the new section is a readable operation-specific view.

Use browser-local timestamps where timestamps are shown.

---

# Part F: integrate status into Invite management UI

Both Invite management surfaces should understand Action Review state.

## Avoid N+1

Do not query ActionReviewRequest once per Invite row.

For the Invite rows being rendered, preload/index Action Review requests in one query, e.g. by:

- operation_type = invite_creation
- resource_type = Invite
- resource_id IN visible invite ids

There should normally be at most one creation-review row per Invite, but choose deterministically if needed.

A small shared lookup/helper is fine.

## User Invite list (/invites)

For an Invite with a creation review:

### pending
- show "Waiting for approval"
- DO NOT render public invite URL
- DO NOT render copy button
- do not offer normal delete/expire action as though it were an active code

### rejected
- show "Stopped"
- DO NOT render URL/copy button
- remains unusable

### approved
- render normal existing Invite behavior
- if it later naturally expires/exhausts, normal expired behavior applies

Invite without Action Review:
- unchanged

The user does not need to see signal/policy/internal reason codes.

## Admin Invite list (/admin/invites)

Same safety behavior for code visibility.

Additionally:

- pending row should show a link to its Action Review detail
- rejected row should show stopped/rejected review status
- approved row may show a small approved-review marker if clean, but must otherwise behave as a normal invite

Add Admin filter(s):

- review pending
- review stopped/rejected

Keep existing all / available / expired filters.

Implement through InviteFilter without per-row queries.

Suggested params:
- `review_pending=1`
- `review_rejected=1`

Add to InviteFilter::KEYS and query using ActionReviewRequest subqueries.

Do not redefine `Invite.available` globally just for Action Review.

---

# Part G: settings UI wording

`invite_creation` is no longer a future/unintegrated adapter.

Update Action Review settings help copy:

- off: invite codes are issued immediately as before
- always: every invite creation waits for staff approval before the code becomes usable

Detectorless operation continues to expose ONLY off/always.

Do not add low/medium/high for Invite creation.

Account migration and status import remain unintegrated; their wording should remain accurate.

---

# Part H: pending shell registration safety tests

This is critical.

Add integration/model/controller coverage proving that a pending invite code cannot be used to register.

At minimum:

1. policy always -> pending Invite shell is persisted
2. pending shell `valid_for_use?` is false
3. `Invite.available` does not include it
4. Auth::RegistrationsController#set_invite / registration path does not accept the pending code
5. approval -> code becomes usable according to requested duration/max_uses and existing user.functional? rule
6. rejected -> code remains unusable
7. no code URL is rendered to creator/admin while pending/rejected

Use the existing registration controller semantics rather than mocking valid_for_use? away.

---

# Part I: destroy/deactivate edge cases

Pending/rejected shells are already expired.

Do not accidentally allow ordinary Invite destroy UI to imply a pending request was cancelled.

For pending/rejected rows, hide the normal delete/expire action.

Direct destroy on an already-expired pending shell may remain an idempotent expire operation if that is simplest, but it MUST NOT:

- approve it
- cancel/flip the ActionReviewRequest
- make it usable

Document this behavior in a spec.

`Admin::InvitesController#deactivate_all` uses `Invite.available`; pending shells are excluded because they are expired. Add a regression spec that deactivate_all cannot make a pending shell usable or alter its Action Review state.

Do not add requester-cancel workflow in this PR.

---

# Part J: exact policy semantics

Invite creation has no automated detector.

Truth table:

```text
off + signal none
  -> save normal Invite
  -> no ActionReviewRequest
  -> usable per normal Invite rules

always + signal none
  -> save expired pending Invite shell
  -> create pending ActionReviewRequest
  -> code unusable until approved
```

No evaluator unavailable state is expected in this operation.

No risk/identity/reputation logic.

---

# Tests

Add focused coverage for at least:

## Creation service

1. off creates normal Invite and no review
2. always creates expired shell + pending review atomically
3. shell retains requested max_uses/autofollow/comment
4. evidence stores requested expires_in, not code/URL/comment text
5. no-expiry request stores null duration
6. validation failure creates neither persisted Invite nor review
7. ActionReview creation failure rolls back Invite
8. malformed setting effective-always also creates held shell

## Both controllers

9. user InvitesController uses service
10. Admin::InvitesController uses service
11. pending redirect notice
12. validation re-render preserves errors/list
13. existing authorization unchanged

## Registration safety

14. pending valid_for_use? false
15. pending excluded from Invite.available
16. pending invite code not accepted by registration
17. approved invite accepted by registration
18. rejected invite not accepted
19. approved finite expiry starts at approval time, not request time
20. no-expiry approval restores expires_at=nil

## Adapter

21. registered in AdapterRegistry
22. approve pending -> request approved + Invite activated
23. reject pending -> request rejected + Invite remains expired
24. reviewer/time/note persisted
25. approve/reject create no ModerationAction
26. actor/resource mismatch fails closed
27. missing resource fails closed
28. used pending shell / inconsistent shell fails closed
29. repeated approve is no-op and does not extend/reactivate expired/used approved invite
30. repeated reject is no-op
31. opposite terminal decision fails
32. concurrent moderators exactly one winner

## Generic Action Review UI

33. existing Follow Import controls still render
34. pending Invite creation renders approve/stop
35. rejected/approved Invite review renders no controls
36. malformed/missing Invite resource shows warning/no controls
37. Invite detail section renders requested factual parameters
38. pending/rejected detail does not expose code/URL

## Invite lists

39. pending user row hides code/copy, shows waiting
40. rejected user row hides code/copy, shows stopped
41. approved row restores normal URL behavior
42. normal non-reviewed Invite unchanged
43. admin pending row links to Action Review
44. admin pending/rejected hide code
45. preload avoids per-row ActionReview query (test lookup behavior at service/controller boundary rather than brittle query-count if preferred)

## Admin filters

46. review_pending returns only pending-reviewed invites
47. review_rejected returns only rejected-reviewed invites
48. existing available/expired filters still work
49. pending shell is naturally in expired semantics but review_pending gives explicit workflow view

## Edge cases

50. direct destroy of pending shell cannot alter review or make code usable
51. deactivate_all leaves pending review state unchanged and code unusable
52. owner becoming non-functional after approval still makes valid_for_use? false through existing rule

## Settings

53. Invite setting offers only off/always
54. copy states adapter is live
55. account_migration/status_import remain described as not integrated

## Regression

56. Follow Import Action Review adapter/controls remain green
57. generic DecisionService remains green
58. Action Review queue/filter/settings remain green
59. no DB migration/schema change

---

# No migration

Prefer no DB migration.

The persisted Invite row is the resource. Pending state is represented by:

- ActionReviewRequest pending
- Invite expired/unusable

Do not add an Invite pending column in this PR.

If implementation proves this unsafe, stop and report rather than casually changing schema.

---

# Validation

Run focused specs for:

- Invite model/Expireable behavior touched
- new Invite creation service
- InvitesController
- Admin::InvitesController
- InviteFilter
- registration controller invite handling
- Action Review adapter/registry/decision service
- Admin ActionReviews controller/helper/view
- Action Review settings form/controller
- existing Follow Import decision specs as regression

Run RuboCop on every changed Ruby/spec file.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Connect Invite creation to Action Review`

PR body must state:

- second live Action Review operation
- detectorless off/always only
- always creates an expired, unusable Invite shell before review
- pending/rejected code URL is hidden in management UI
- approval restores expiration starting at approval time
- rejection leaves shell unusable
- both user and admin creation paths are covered
- Admin Invite list gets review pending/rejected filters
- generic Action Review controls are adapter-driven, no longer FollowImport-hardcoded
- no ModerationAction
- no identity/risk classification
- no DB migration
- exact RSpec/RuboCop results

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR number/URL
- head/base SHA
- exact changed files
- create service interface/result semantics
- pending shell invariant
- exact Action Review evidence schema
- adapter state machine
- idempotency/concurrency behavior
- registration-safety proof
- Action Review UI changes
- Invite user/admin list changes
- Admin filter params
- settings copy changes
- exact RSpec results
- exact RuboCop result
- any deviation or unresolved concern
