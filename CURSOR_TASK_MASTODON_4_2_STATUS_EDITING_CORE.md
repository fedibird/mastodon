# Cursor task: Mastodon 4.2 status editing core for Fedibird

## Goal

Backport the complete **local status editing** contract needed for Mastodon 4.2 API compatibility, while preserving Fedibird-specific status semantics.

This PR should make a locally-owned status genuinely editable through:

- `PUT/PATCH /api/v1/statuses/:id`
- `GET /api/v1/statuses/:id/history`
- existing `GET /api/v1/statuses/:id/source`

and make local edits propagate as status updates to local clients and remote ActivityPub recipients.

Remote inbound ActivityPub Note/Question Update ingestion is explicitly a **follow-up PR**. Do not add the large remote ProcessStatusUpdateService in this PR.

## Branch / base

Work on:

`feature/mastodon-4-2-status-editing-core`

Base:

`2b423bcb046bdcfdb405d21551f85348c48a5059`

This base includes #157.

## Upstream reference

Use Mastodon `v4.2.0` as the primary behavioral/API reference.

Important upstream files to study:

- `app/controllers/api/v1/statuses_controller.rb`
- `app/controllers/api/v1/statuses/histories_controller.rb`
- `app/controllers/api/v1/statuses/sources_controller.rb`
- `app/models/status_edit.rb`
- `app/models/concerns/status/snapshot_concern.rb`
- `app/serializers/rest/status_edit_serializer.rb`
- `app/serializers/rest/status_serializer.rb`
- `app/services/update_status_service.rb`
- `app/workers/activitypub/status_update_distribution_worker.rb`
- `app/serializers/activitypub/note_serializer.rb`
- `app/policies/status_policy.rb`
- `app/services/process_mentions_service.rb`
- `app/services/process_hashtags_service.rb`

Do NOT blindly replace Fedibird files with upstream versions. Fedibird status behavior diverges significantly.

---

# Current Fedibird state

Fedibird currently has:

- `GET /api/v1/statuses/:id/source` implemented
- `GET /api/v1/statuses/:id/history` route/controller, but it is a stub returning `[]`
- no `PUT/PATCH /api/v1/statuses/:id` route/action
- no `statuses.edited_at`
- no `status_edits` table/model
- no `UpdateStatusService`
- no outbound `ActivityPub::StatusUpdateDistributionWorker`
- ActivityPub Note serializer does not emit `updated`
- incoming ActivityPub Update only handles Actor types and Question poll refresh, not Note edits

Fedibird also has custom status semantics that must survive:

- quote / `quote_id`
- StatusReference / `references`
- `searchability`
- expiry / `status_expire` / `expired_at`
- circles and limited visibility
- personal/mutual/custom visibilities
- emoji reactions
- tag/keyword/domain/account subscriptions
- custom streaming/filterable text behavior
- tag mute semantics
- generator/application behavior
- configurable attachment limit
- optional poll-image setting
- moderation interaction recording in ProcessMentionsService
- time-limit hashtag behavior in ProcessHashtagsService

---

# Part A: schema

Add one or two new 2026 migrations, not the historical upstream migration timestamps.

## statuses

Add:

```ruby
edited_at :datetime, null: true
```

No backfill.

Existing rows remain unedited.

## status_edits

Create the Mastodon 4.2-compatible final table:

```text
id
status_id                    bigint not null FK ON DELETE CASCADE
account_id                   bigint nullable FK ON DELETE SET NULL
text                         text not null default ''
spoiler_text                 text not null default ''
ordered_media_attachment_ids bigint[] nullable
media_descriptions           text[] nullable
poll_options                 string[] nullable
sensitive                    boolean nullable
created_at
updated_at
```

Indexes on:

- status_id
- account_id

Do not add quote/reference/expiry/searchability columns to StatusEdit in this PR. They are not editable through Mastodon 4.2 status-edit API.

No backfill of historical edits.

---

# Part B: Status snapshot model

Backport a Fedibird-adapted `Status::SnapshotConcern`.

Include it into Status.

Required:

- `has_many :edits, class_name: 'StatusEdit', dependent: :destroy`
- `edited?`
- `build_snapshot(account_id: nil, at_time: nil, rate_limit: true)`
- `snapshot!`

Snapshot:

- text
- spoiler_text
- sensitive
- ordered media attachment IDs
- media descriptions
- poll options
- account/editor
- snapshot timestamp

For the initial snapshot use status.created_at.

For the current edit use status.edited_at/current edit time.

Do not snapshot or mutate Fedibird-only quote/reference/expiry/searchability/circle state.

---

# Part C: StatusEdit model and REST serializer

Backport `StatusEdit` behavior from Mastodon 4.2.

Use final 4.2 schema, not old transitional columns.

StatusEdit must provide historical:

- content
- spoiler_text
- sensitive
- created_at
- account
- media_attachments
- poll options
- emojis

Add `REST::StatusEditSerializer` matching Mastodon 4.2 entity shape.

Media descriptions must reflect the description at that historical edit, not the attachment's latest description.

If an attachment is still available, serialize its historical description with the preserved attachment wrapper.

Handle deleted editor account safely because account_id is nullable / ON DELETE SET NULL.

Add focused model/serializer specs.

---

# Part D: REST Status entity

Add:

`edited_at`

to `REST::StatusSerializer`.

Do NOT remove or repurpose Fedibird's existing extra `updated_at` field.

Contract:

- never edited -> edited_at null
- edited -> edit timestamp

Nested/reblog/quote serializers should inherit this normally.

Do not use StatusStat.updated_at as edited_at.

---

# Part E: history endpoint

Replace the current stub:

`Api::V1::Statuses::HistoriesController#show`

with Mastodon 4.2-compatible behavior.

Requirements:

- optional read token / `read:statuses` like upstream
- load status
- apply normal `StatusPolicy#show?`
- inaccessible/private -> 404 as normal status visibility contract
- public visible status can be read unauthenticated
- serialize with `REST::StatusEditSerializer`

For never-edited status:

- return one synthetic snapshot representing current/original status
- timestamp = edited_at || created_at (normally created_at)

For edited status:

- return stored snapshots oldest -> newest
- first entry represents original state
- final entry represents current state

Do not return an empty array for an ordinary existing unedited status.

Keep source endpoint behavior unchanged.

Tests:

- public unauth history
- private unauthorized 404
- private authorized/follower behavior according to show policy
- never-edited one snapshot
- one edit -> original + current
- multiple edits ordered
- deleted editor safe

---

# Part F: API edit endpoint

Add `:update` to v1 statuses resources/routes and controller.

Accept Mastodon 4.2 edit parameters:

- status
- spoiler_text
- sensitive
- language
- media_ids[]
- media_attributes[]:
  - id
  - description
  - focus
  - thumbnail if current Fedibird MediaAttachment supports upstream semantics
- poll:
  - options[]
  - multiple
  - hide_totals
  - expires_in

Do NOT make these editable:

- visibility
- in_reply_to_id
- quote_id
- status_reference_ids / status_reference_urls
- circle_id
- searchability
- expires_at / expires_in / expires_action
- application/generator

An edit must not silently mutate those fields.

## Authorization

Mastodon API semantics: only the owning account may edit its status.

Important Fedibird conflict:

Current `StatusPolicy#update?` is used as a **staff moderation authorization** by `Admin::StatusesController#create`.

Do not simply change `update?` to `owned?` and break admin moderation.

Choose a clean separation, e.g.:

- make `StatusPolicy#update?` mean owned local API edit, as upstream
- add a dedicated staff policy action such as `moderate?` for admin batch status operations
- change `Admin::StatusesController#create` to authorize that staff action

or an equivalent explicit separation.

Do not use ambiguous logic where staff can edit another user's content through the public status-edit API.

API edit of another user's status must return 404/not found style behavior, not expose existence unnecessarily.

Add policy/controller regression specs for both:

- owner API edit allowed
- other account API edit denied
- admin moderation batch remains allowed
- normal non-staff cannot use admin moderation action

---

# Part G: UpdateStatusService

Backport/adapt Mastodon 4.2 `UpdateStatusService`.

Transaction requirements:

1. create original snapshot only on first actual edit
2. apply requested media/poll/immediate attribute changes
3. validate
4. save status with new edited_at
5. create current snapshot
6. no partial edit history if transaction fails

No-change request:

- returns current status successfully
- does not create another edit snapshot
- does not advance edited_at
- does not broadcast/federate a fake edit

## Text/CW/sensitive/language

Match Mastodon 4.2 behavior where practical.

Preserve Fedibird StatusLengthValidator / prohibited status validation through normal model save.

Do not allow edit to bypass account suspension or normal write restrictions.

If current_user.setting_disable_post should also prevent editing, characterize current intended behavior and choose the conservative consistency with create; document it.

## Media

Adapt upstream logic to Fedibird:

- use `Setting.attachments_max`, not hard-coded 4
- respect existing `Setting.allow_poll_image`
- only media owned by the status account
- media must be unattached or already attached to this status as appropriate
- no cross-account attachment stealing
- preserve ordered_media_attachment_ids
- historical media descriptions retained in snapshots
- edit description/focus/thumbnail only for selected/owned media
- removed media behavior should match upstream 4.2 where possible

## Poll

Match upstream behavior:

- edit options/multiple/etc
- changing options or multiple choice resets previous votes
- removing a poll supported if upstream 4.2 supports it
- poll history snapshot retains option titles
- expiration notification scheduling updated correctly

Use existing Fedibird Poll services/settings where they diverge.

---

# Part H: make hashtag processing edit-safe

Current Fedibird `ProcessHashtagsService` is creation-oriented and only appends tags.

An edit must make `status.tags` reflect current text.

Adapt the service or add a small edit mode so an edited local status:

- adds new hashtags
- removes no-longer-present hashtags
- updates featured-tag counters correctly
- retains Fedibird tag-mute semantics elsewhere

Do not globally regress creation behavior.

## Fedibird time-limit hashtags

Current ProcessHashtagsService can change expiry based on TimeLimit hashtags.

Mastodon 4.2 status-edit API does NOT expose expiry editing.

For this PR:

**Editing ordinary status text must preserve the status's existing expiry/expiration state.**

Do not let hashtag reprocessing during edit unexpectedly:

- create a new expiry
- change expiry
- clear expiry

If needed, add an explicit option to ProcessHashtagsService so creation keeps current time-limit behavior while UpdateStatusService performs tag replacement without expiry mutation.

Add regression specs.

---

# Part I: make mention processing edit-safe

Current Fedibird `ProcessMentionsService` is creation-oriented.

Backport the important Mastodon 4.2 edit semantics while preserving Fedibird extensions:

- reuse existing active mention records where possible
- create newly introduced explicit mentions
- removed explicit mentions become silent rather than being deleted, so already-granted visibility/notifications are not withdrawn confusingly
- do not duplicate mention rows on repeated edits
- preserve existing silent audience mentions for limited/circle statuses
- do not reconstruct or change the circle audience merely because text was edited
- do not change visibility
- preserve blocked/suspended/undeliverable account handling

Fedibird-specific moderation recording:

- keep `Moderation::EventRecorder` mention/reply recording
- record only genuinely newly-created explicit mention interactions
- do not create duplicate moderation interaction records just because an existing mention survived an edit

Notifications:

- newly introduced local mentions may notify as normal
- existing unchanged mentions must not generate duplicate "new mention" semantics merely from a no-op/repeated edit

Add focused specs.

---

# Part J: preserve Fedibird-only status semantics

Explicit regression tests are required.

After an ordinary Mastodon 4.2 edit:

## Quote

- `quote_id` unchanged
- quote relation remains intact
- API edit cannot replace/remove quote

## StatusReference

- existing reference relationships unchanged
- edit does not wipe references
- edit API cannot inject new `status_reference_ids/urls`

## Searchability

- unchanged

## Expiry

- `status_expire`, `expired_at`, configured expiry timestamp/action unchanged

## Visibility / circle

- visibility unchanged
- limited/personal/mutual semantics unchanged
- existing silent audience mentions retained
- circle_id is not editable through this API

## Generator/application

- unchanged

These are important because blindly replacing PostStatus-like metadata would destroy intentional Fedibird semantics.

---

# Part K: local streaming/update fan-out

A local edit must be observable by clients without pretending it is a brand-new post.

Backport/adapt the upstream "status.update" fan-out semantics into Fedibird's existing custom FanOut/FeedManager architecture.

Important current Fedibird differences:

- `FanOutOnWriteService#call(status)` currently has no update option
- FeedManager push methods do not accept update
- `PushUpdateWorker` always emits event `update`
- Fedibird has extra destinations:
  - domain subscribes
  - account subscribes
  - list subscribes
  - hashtag follows with home/list routing
  - keyword subscribes
  - group timelines
  - index/media/nomedia streams

Implement a minimal, coherent update mode.

Required principles:

1. existing recipients should receive a `status.update` streaming event for the edited status, not a second "new status" event
2. do not generate duplicate status notifications merely because an existing post was edited
3. newly-added explicit mentions should still get appropriate mention handling
4. feed insertion/reinsertion must be idempotent
5. an edit must not create duplicate feed rows
6. custom Fedibird subscription paths must not crash under update mode
7. `_fedibird_searchable_text` must reflect the edited status text/URLs for streaming filter matching
8. Keyword Subscribe matching uses the edited current `MatchingText`
9. hashtag/tag-follow paths use current tags
10. personal statuses must remain local-only

Do not redesign the whole fan-out service. Add an update option and thread it only as far as needed.

If exact upstream behavior does not map cleanly to a Fedibird-only destination, choose the least surprising idempotent update behavior and document it in the PR.

Add focused worker/service specs proving:

- home timeline update event = status.update
- list update event = status.update
- public stream update event = status.update
- no duplicate normal status notification
- edited filterable/searchable transport is current
- keyword/tag subscriber paths do not emit a duplicate normal create event for an already-present status

---

# Part L: outbound ActivityPub Update

Add/adapt upstream:

`ActivityPub::StatusUpdateDistributionWorker`

On a successful local edit:

- distribute an ActivityPub `Update`
- actor = status account
- object = current edited status Note/Question
- published = edited_at
- deterministic Update ID:
  `<status-uri>#updates/<edited_at.to_i>`
- use normal status audience (to/cc)
- preserve Fedibird NoteSerializer extensions:
  - quote
  - references
  - expiry
  - searchability extensions
  - emoji reactions etc as currently serialized

Update `ActivityPub::NoteSerializer`:

- emit `updated` iff status.edited?
- value = edited_at.iso8601

Do not replace NoteSerializer with upstream.

Do not send ActivityPub for personal-only statuses if they are intentionally non-federated today.

Add serializer/worker specs:

- edited Note has `updated`
- unedited Note does not
- outgoing Update ID deterministic
- Update object still contains Fedibird quote/reference extensions when present
- private/limited audience preserved
- personal behavior preserved

---

# Part M: incoming remote edits are OUT OF SCOPE

Do NOT add in this PR:

- `ActivityPub::ProcessStatusUpdateService`
- Note/Question Update handling in `ActivityPub::Activity::Update`
- remote status history snapshots
- remote edit media downloads

Keep current Question poll update behavior working.

The next PR will specifically backport remote ActivityPub status Update ingestion.

Mention this explicitly in the PR body.

---

# Part N: API tests

At minimum:

## update endpoint

- requires write:statuses
- read-only scope denied
- owner can edit
- non-owner cannot edit
- text edit
- CW edit
- sensitive edit
- language edit
- media reorder
- media description edit
- poll edit
- no-op
- validation failure rollback
- edited_at returned
- original/current history created atomically

## forbidden/unaccepted fields

Prove these do not change when supplied:

- visibility
- quote_id
- status_reference_ids
- searchability
- expires_at/expires_in/expires_action
- circle_id

## history

As above.

## source

Run existing source controller specs unchanged.

---

# Part O: regression suites

Run focused existing tests for:

- statuses API controller
- status serializer
- status policy
- source controller
- Admin::StatusesController
- PostStatusService
- ProcessMentionsService
- ProcessHashtagsService
- FeedManager / FeedInsertWorker / PushUpdateWorker
- FanOutOnWriteService
- ActivityPub Note serializer / distribution worker
- polls/media attachment update behavior
- Keyword Subscribe and filterable text paths touched by update mode

Compare failures against current fedibird if broad old specs have baseline failures.

Run RuboCop on every changed Ruby/spec file.

---

# PR shape

One Draft PR against `fedibird`.

Suggested title:

`Backport Mastodon 4.2 local status editing`

PR body must include:

- upstream v4.2 files used as reference
- exact schema additions
- exact API fields supported
- fields intentionally not editable
- history behavior
- policy split for owner edit vs staff moderation
- hashtag/mention edit semantics
- Fedibird quote/reference/searchability/expiry/circle preservation
- streaming status.update behavior
- outbound ActivityPub Update behavior
- explicit statement that inbound remote edits are follow-up
- exact tests/RuboCop
- any deviations from upstream and why

Delete this handoff file before final diff.

## Completion report

Return:

- Draft PR number / URL
- head/base SHA
- migration names
- changed files
- update endpoint contract
- history contract
- snapshot schema/semantics
- policy changes
- hashtag/mention edit behavior
- Fedibird fields preservation proof
- local streaming update behavior
- ActivityPub outbound update proof
- exact RSpec result
- exact RuboCop result
- baseline failures
- follow-up notes for remote inbound status Update
