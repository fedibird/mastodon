# Cursor task: Action Review admin queue and policy settings UI

## Context

PR #148 added the generic Action Review foundation:

- `ActionReviewRequest`
- `ActionReview::OperationRegistry`
- `ActionReview::PolicySettings`
- `ActionReview::PolicyDecisionService`
- `ActionReview::RequestService`
- site setting `action_review_policies`

PR #147 added the durable Follow Import preflight execution barrier.

We now need the generic Admin UI layer:

1. a moderator-visible Action Review queue / history
2. an admin-only site policy settings page

This PR is still generic. It MUST NOT yet connect Follow Import, migration, invite creation, or future status import to Action Review execution.

It also MUST NOT add approve/reject side effects yet.

The next PR will connect Follow Import and add safe decision adapters / endpoints.

## Why no approve/reject buttons yet

Do not create a UI that can set an ActionReviewRequest to approved/rejected before there is an operation adapter that atomically releases/stops the underlying resource.

Otherwise we could produce:

- request says approved
- underlying Follow Import remains held

or worse:

- request says rejected
- underlying operation still executes

So this PR provides queue visibility and configuration only.

## Branch / base

Work on:

`feature/action-review-admin-ui`

Base commit:

`2944ca4a4c4f1f7ac8f81fde782ea88ec9b26373`

(#148 merged)

## Part A: Admin Action Review queue

### Routes

Add Admin routes for generic action reviews, suggested:

```ruby
namespace :admin do
  resources :action_reviews, only: [:index, :show]
end
```

Naming deviations are fine if consistent.

### Authorization

Queue access should be available to staff (moderator/admin), matching reports.

Add a policy, suggested:

`ActionReviewRequestPolicy`

- index? -> staff?
- show? -> staff?

The policy settings page below is admin-only.

Do not rely only on navigation visibility.

### Index page

Create a generic queue/history page.

Default filter:
- pending

Support at least:
- pending
- approved
- rejected
- cancelled
- all

Order:
- pending oldest-first by requested_at, so oldest waiting work is visible first
- non-pending/history newest-first is acceptable

Paginate.

Each row should show factual metadata only:

- operation type
- actor account if still present
- requested time, using existing browser-local `time.formatted` helper/pattern
- signal level
- trigger
- policy mode
- short reason code summary
- resource type / id
- state

Do not render raw `evidence` JSON on the index page.

Unknown/deleted actor/resource must render gracefully.

### Pending count / navigation signal

Add Action Review under the moderation navigation area.

If pending count > 0, show the count in the navigation label or another existing lightweight admin-navigation pattern.

The queue is the authoritative durable notification surface.

Do not add email/push notifications in this PR.

Avoid an expensive query pattern. A single `ActionReviewRequest.pending_state.count` for staff navigation is acceptable unless an existing helper/cache pattern is clearly better.

### Show page

Display the complete audit snapshot in readable sections:

- state
- operation
- actor account
- resource identity
- requested_at
- signal_level
- trigger
- policy_mode
- policy_version
- evaluator_version
- reason_codes
- evidence
- reviewed_at / reviewer / decision_note if present

Important:

- use browser-local time rendering for timestamps
- evidence must be safely escaped / rendered as structured key-value or pretty JSON in a `pre` block
- never mark evidence HTML safe
- tolerate deleted actor/reviewer/resource
- do not infer labels like dangerous / malicious / same person
- no approve/reject controls yet

### Resource links

Where a safe generic admin link is obvious, it is acceptable to link.

Do NOT build a large type-switch just for this PR.

At minimum show `resource_type #resource_id` reliably.

Future operation-specific presenters can improve this.

### Query behavior

Avoid N+1 for actor/reviewer where practical.

The polymorphic resource does not need to be eagerly loaded if that complicates the generic query.

## Part B: Action Review policy settings page

Create a dedicated admin-only page instead of expanding the already-large general Admin Settings screen.

Suggested route/controller:

- `GET /admin/action_review_settings/edit`
- `PATCH /admin/action_review_settings`

or a similarly conventional resource.

Authorization:
- admin only

A small policy such as `ActionReviewSettingsPolicy`, or reuse a suitable admin settings policy if semantically clean.

### Form model

Prefer a dedicated form object, e.g.:

`Form::ActionReviewSettings`

It should read/write the existing `Setting['action_review_policies']` hash.

Do not create new DB columns.

Requirements:

- preserve registered operation keys not rendered/changed by the form
- validate every submitted mode against `OperationRegistry.supported_policy_modes(operation)`
- do not silently persist unsupported detectorless thresholds
- persist canonical strings
- failed validation re-renders with errors
- successful save invalidates/updates Setting cache through the normal RailsSettings path

### Operations displayed

Display the four registry operations:

- follow_import
- account_migration
- invite_creation
- status_import

Be explicit in help text that only the policy framework is configured here; operation integration is rolled out separately.

Current capability choices:

#### follow_import
Show 5 choices:

- off
- high
- medium
- low
- always

#### account_migration / invite_creation / status_import
Show only:

- off
- always

Do not expose low/medium/high for detectorless operations.

For `status_import`, clearly label it as future / not yet implemented so admins are not misled into believing the feature exists.

For the other operations, also make clear that enforcement takes effect only once that operation's Action Review adapter is integrated. This PR itself changes no execution behavior.

### Labels / descriptions

Use human-readable wording in locales.

For Japanese, suggested conceptual wording:

Policy levels:
- off: 介入しない
- high: 高い要確認シグナルのみ
- medium: 中以上
- low: 低以上
- always: 常にモデレーター承認

Avoid wording that calls the signal a danger/risk/guilt level.

Use language like:
- 要確認シグナル
- 承認介入の感度
- 判断待ち

Operation labels:
- フォローインポート
- アカウントの引っ越し
- 招待コードの発行
- 投稿データのインポート（将来機能）

English locales too.

### Settings semantics

This page only edits the existing `action_review_policies` setting.

Defaults remain all off.

No policy change should create ActionReviewRequest rows by itself.

No background reevaluation of existing resources.

## Part C: audit/history semantics

The index should be capable of showing future non-pending rows, even though this PR does not transition them.

Do not add fake seeded rows.

Do not add state transition endpoints yet.

Do not add batch approve/reject.

## Part D: navigation

Under Moderation, add Action Review queue.

Under Admin, add Action Review settings for admins only.

Suggested navigation concepts:

Moderation:
- 判断待ち / Action reviews
- include pending count when nonzero

Admin:
- 操作の承認ポリシー / Action review policies

Use existing icon vocabulary; do not introduce assets.

## Important non-goals

DO NOT:

- integrate Follow Import execution
- call PolicyDecisionService from ImportService
- transition FollowImportBatch to review_required
- add recurrence classifier
- define low/medium/high thresholds
- approve/reject an ActionReviewRequest
- release or stop any resource
- add operation adapters
- send mail/push notifications
- change RiskEvaluation
- change AdaptiveFollowGateDecisionService
- add identity inference
- add moderation actions
- change migration / invite / import behavior
- add DB migrations unless absolutely necessary for UI performance (prefer none)

## Tests

Add focused coverage for at least:

### Authorization
1. moderator can view queue index/show
2. admin can view queue index/show
3. ordinary user cannot
4. only admin can edit/update Action Review policy settings
5. moderator cannot change site policy

### Queue index
6. defaults to pending
7. pending ordered oldest first
8. state filters work
9. all works
10. pagination uses normal app behavior
11. deleted actor renders safely
12. pending count is correct
13. no raw evidence rendered on index
14. timestamp uses browser-local formatted markup

### Queue show
15. displays audit snapshot fields
16. evidence is escaped, not HTML-safe
17. reason codes display
18. deleted resource does not crash
19. deleted reviewer/actor does not crash
20. timestamps use browser-local formatting
21. no approve/reject controls/routes exist

### Settings form
22. loads defaults off
23. follow_import offers all 5 supported modes
24. detectorless operations offer only off/always
25. valid settings save
26. unsupported detectorless mode fails validation / is not persisted
27. unknown operation input is not persisted
28. preserves keys not being changed where applicable
29. no ActionReviewRequest is created by saving settings
30. normal Setting cache/read path reflects saved values

### Navigation
31. queue visible to staff
32. policy settings visible only to admin
33. pending count appears when > 0
34. pending count absent/zero presentation is sane

## Existing tests

Run relevant:

- Action Review service/model specs from #148
- settings/form/controller specs touched
- navigation specs if present
- admin authorization specs

Run RuboCop on changed Ruby/spec files.

No new lint tooling.

## Locales

Add English and Japanese strings at minimum.

Keep wording neutral and administrative.

Do not call automated signal:
- danger score
- abuse probability
- identity match

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add Action Review admin queue and policy settings`

PR body must state:

- generic queue + settings UI only
- queue is staff-visible, settings admin-only
- no approve/reject actions yet
- no operation is connected/enforced yet
- defaults remain off
- Follow Import shows 5 intervention modes
- detectorless operations show off/always
- pending count is the first durable notification surface
- timestamps use browser-local formatting
- no migration
- no identity/risk inference

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head/base SHA
- exact changed files
- routes/controllers/policies added
- queue filters/order
- navigation behavior
- settings form structure
- exact operation/mode choices shown
- locale additions
- exact RSpec results
- exact RuboCop result
- any design deviation / unresolved concern
