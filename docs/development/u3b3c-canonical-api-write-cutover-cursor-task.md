# Cursor task: U3b-3c canonical API write cutover

## Purpose

Implement U3b-3c of the hashtag subsystem upstream-unification project.

This stage cuts the Fedibird compatibility API mutation path over to canonical
TagFollow + TagFollowDelivery while preserving the legacy follow_tags table as
an exact rollback shadow.

Current production state:

- U3a: legacy FollowTag writes mirror into TagFollow + TagFollowDelivery
- U3b-1: standard relation reads use TagFollow
- U3b-2: FanOut / FeedManager delivery reads use TagFollowDelivery
- U3b-3a: TagFollowDelivery stores legacy_follow_tag_id
- U3b-3b:
  - GET /api/v1/follow_tags and GET show read TagFollowDelivery
  - Settings index reads TagFollowDelivery
  - API create/update/destroy and Settings forms/writes still use FollowTag
- production compatibility parity was confirmed before U3b-3b:
  - ok: true
  - management_ready: true

U3b-3c changes only the API create/update/destroy mutation authority.

## Scope

Cut these API actions to canonical writes:

- POST /api/v1/follow_tags
- PUT/PATCH /api/v1/follow_tags/:id
- DELETE /api/v1/follow_tags/:id

Keep these unchanged:

- API index/show already canonical from U3b-3b
- Settings new/create/edit/update/destroy remain legacy FollowTag for now
- Api::V1::TagsController standard follow/unfollow remain legacy FollowTag
- U3a FollowTag callbacks/mirror remain in place for those still-legacy paths
- FanOut / FeedManager remain canonical reads
- Tag identity remains unchanged

This is intentionally not the Settings form cutover. That is a later U3b-3d.

## Core architecture

After U3b-3c:

    Fedibird compatibility API
      read  -> TagFollowDelivery
      write -> canonical writer
                -> TagFollow / TagFollowDelivery
                -> legacy follow_tags shadow (same transaction)

    Settings form/write
      -> FollowTag
      -> U3a mirror
      -> canonical

    standard TagsController write
      -> FollowTag
      -> U3a mirror
      -> canonical

The API must no longer save/destroy FollowTag Active Record objects.

## Rollback requirement

Every successful canonical API mutation must leave legacy follow_tags in exact
semantic parity.

This enables application-code rollback:

    deploy problem
      -> revert to U3b-3b
      -> legacy FollowTag write path is still complete/current

Do not remove FollowTag, FollowTagMirror, backfill, or parity.

Do not reverse the existing U3a mirror yet.

## Compatibility resource IDs

Existing API resource IDs remain legacy_follow_tag_id.

For newly created canonical API resources, allocate the public compatibility ID
through the existing follow_tags primary-key sequence.

Do NOT create an independent sequence in this PR.

Reason:

- legacy writers are still active in Settings and Api::V1::TagsController
- a second allocator could issue colliding IDs
- inserting the legacy shadow row lets PostgreSQL use the same follow_tags
  sequence as every remaining legacy writer

Recommended create order inside one DB transaction:

1. resolve/create canonical Tag
2. find/create TagFollow(account, tag)
3. create canonical TagFollowDelivery with legacy_follow_tag_id temporarily nil
4. INSERT the legacy follow_tags shadow row without callbacks and RETURNING id
5. assign that returned id to delivery.legacy_follow_tag_id
6. commit

All steps must be atomic.

A sequence gap after transaction rollback is acceptable.

Do not call FollowTag.create! merely to obtain an ID because that would execute
U3a callbacks and make the legacy model drive the canonical write again.

Use raw SQL or a callback-bypassing insert that returns the generated primary
key.

## New writer service

Create a focused service, recommended name:

    HashtagUnification::TagFollowDeliveryWriter

Equivalent name is acceptable if equally explicit.

It should own:

- canonical destination creation
- canonical destination update/movement
- canonical destination destruction
- legacy shadow insert/update/delete
- parent TagFollow cleanup
- compatibility-ID preservation

Keep controller code thin.

The service should be reusable by the later Settings write cutover, but do not
over-engineer a broad framework.

A practical public API may be:

    create!(account:, name:, list: nil, media_only: false)
    update!(account:, legacy_resource_id:, name: UNCHANGED, list: UNCHANGED, media_only: UNCHANGED)
    destroy!(account:, legacy_resource_id:)

The exact API may differ if clearer.

Supporting list as an optional generic destination is encouraged so U3b-3d can
reuse the service, even though the API create action currently creates Home
only.

## Tag resolution semantics

Preserve current FollowTag#name= behavior as closely as practical:

    Tag.find_or_create_by_names(name.strip)&.first

Do not introduce HashtagNormalizer or upstream Tag identity changes here.

When Tag creation/validation fails, the API must still return a validation
error (422), not create an invalid relation.

A reasonable implementation:

- resolve via Tag.find_or_create_by_names
- if the resulting Tag is not persisted/valid, raise
  ActiveRecord::RecordInvalid for that Tag

Do not silently normalize beyond current Fedibird Tag behavior.

## Create semantics

POST /api/v1/follow_tags currently accepts:

- name
- media_only

It creates an explicit Home destination.

Required canonical result:

    TagFollow(account, resolved tag)
      TagFollowDelivery(
        list_id: nil,
        media_only: requested/default false,
        legacy_follow_tag_id: generated shadow id
      )

Required legacy shadow:

    follow_tags row with:
      id == delivery.legacy_follow_tag_id
      same account_id
      same tag_id
      list_id NULL
      same media_only
      compatible timestamps

Create must preserve the existing duplicate behavior:

- if Home already exists for account/tag, return 422
- do not create a second Home
- lists-only relation may add a Home destination

Canonical DB/model uniqueness is authoritative.

## Update semantics

PUT/PATCH /api/v1/follow_tags/:id must now locate the canonical delivery by:

    current account + legacy_follow_tag_id

Do not load FollowTag as the mutation object.

The API params remain:

- name
- media_only

list_id is not an API parameter and must remain unchanged.

### Name unchanged

If name is omitted, preserve the current tag.

### Name changed

Changing name moves this one destination to the relation for the new tag:

    old TagFollow(tag A)
      delivery X

    -> update name to tag B

    new/existing TagFollow(tag B)
      delivery X (same list destination)
      same legacy_follow_tag_id

If the old TagFollow has no remaining deliveries after the move, delete it.

If moving would collide with an existing destination on the target TagFollow,
return 422 and roll back both canonical and shadow changes.

### media_only

Preserve current casting/semantics. Assign through the Active Record attribute
so normal boolean casting applies.

### Compatibility ID

The same legacy_follow_tag_id must survive every update, including tag movement.

### Legacy shadow

Update the existing follow_tags row with id == legacy_follow_tag_id so it
matches the canonical destination:

- tag_id
- list_id
- media_only
- updated_at

account_id remains owned by the authenticated resource and should not change.

Do this without callbacks.

## Destroy semantics

DELETE /api/v1/follow_tags/:id:

1. resolve canonical delivery by current account + legacy_follow_tag_id
2. delete canonical delivery
3. delete its legacy follow_tags shadow row by the same compatibility ID
4. if parent TagFollow has no remaining deliveries, delete the TagFollow
5. commit atomically

Do not invoke FollowTag#destroy! from the API mutation path.

Deleting one destination must not delete peer destinations.

## Shadow integrity

During this transition, update/destroy must require the matching legacy shadow
row to exist and belong to the same account/destination identity.

Production parity guarantees that invariant.

If the canonical resource exists but its required legacy shadow is missing or
belongs to an inconsistent account, fail closed rather than silently creating
an untracked rollback state.

A dedicated consistency exception is acceptable, but it must produce a safe
HTTP failure rather than partial mutation.

For create, the writer creates the shadow itself.

## Concurrency / lock order

There are temporarily two mutation paths:

1. canonical API writer
2. legacy Settings/TagsController -> FollowTag callback mirror

Avoid an obvious opposite lock order.

Legacy writes naturally mutate/lock follow_tags first and then U3a touches
canonical rows.

For update/destroy in the canonical writer, prefer:

1. begin transaction
2. lock/verify the legacy shadow row first
3. lock/load the canonical delivery
4. perform canonical + shadow mutation
5. clean up parent relation
6. commit

This follows the same legacy -> canonical lock order and reduces deadlock risk.

Document any intentional deviation.

Create has no existing legacy row, so canonical creation may precede shadow
insert as long as it is one transaction.

## Legacy shadow implementation

Do not instantiate/save FollowTag for shadow synchronization.

Use raw SQL, update_all/delete_all, insert_all with callbacks bypassed, or a
small private SQL helper.

Requirements:

- no FollowTag after_save/after_destroy callback execution
- no recursive mirror
- exact id preservation
- same transaction as canonical mutation

For INSERT, use the existing follow_tags id sequence automatically by inserting
without an explicit id and RETURNING id.

Do not hardcode a second ID allocator.

## API controller changes

Api::V1::FollowTagsController should use canonical delivery lookup for:

- show
- update
- destroy

Create should call the canonical writer.

Update should call the canonical writer and render the returned
TagFollowDelivery through REST::FollowTagSerializer.

Destroy should call the canonical writer then render_empty.

After this PR, the controller should not call:

    FollowTag.create!
    @follow_tag.update!
    @follow_tag.destroy!

for its mutation actions.

Keep current authorization scopes unchanged.

## Serializer

REST::FollowTagSerializer already supports TagFollowDelivery and FollowTag.

The API actions should now return canonical TagFollowDelivery for create/update.

Do not broaden or change the JSON shape:

    id
    name
    updated_at

Do not expose list_id or media_only in this PR.

The transitional FollowTag serializer support may remain because other code or
rollback stages still exist. Do not remove it unless repository-wide proof
shows it is unused and removal is clearly safe.

## Strong read/write authority sentinel

Prove the API no longer relies on FollowTag callbacks.

For focused API/service specs, make FollowTagMirror unusable, for example:

    allow(HashtagUnification::FollowTagMirror).to receive(:new).and_raise(...)

Then exercise API create/update/destroy.

Expected:

- canonical API mutations still succeed
- shadow follow_tags rows stay synchronized
- no U3a callback is needed

Choose a robust equivalent if direct stubbing is awkward.

This is a key acceptance test.

## Required regression matrix

### 1. Create Home

POST name/media_only.

Assert:

- returned object/JSON is canonical
- TagFollow exists
- explicit Home TagFollowDelivery exists
- legacy_follow_tag_id is non-null
- FollowTag shadow row exists with same id/data
- parity reports ok: true
- management_ready remains true

### 2. Create Home on lists-only relation

Pre-create canonical + legacy List destination through the existing legacy path.

POST same tag.

Assert:

- Home is added
- List remains
- one TagFollow relation
- both shadow rows remain
- no implicit destination deletion

### 3. Duplicate Home

Existing Home then POST same tag.

Assert 422 and:

- no extra canonical delivery
- no extra shadow row
- parity remains true

### 4. Update media_only

Update canonical API resource.

Assert:

- same legacy resource ID
- canonical media_only updated
- shadow media_only updated
- no FollowTagMirror dependency
- parity true

### 5. Update tag/name

Move one destination to a different tag.

Assert:

- compatibility ID unchanged
- destination points to new TagFollow
- shadow row tag_id matches
- old TagFollow deleted if now empty
- old TagFollow retained if another destination remains
- parity true

### 6. Update collision

Move a destination onto a tag that already has the same Home/List destination.

Assert 422 and full rollback.

### 7. Destroy one peer destination

Home + List or multiple Lists.

Destroy one by API ID.

Assert:

- only that canonical destination disappears
- only matching shadow row disappears
- relation survives when another destination remains
- parity true

### 8. Destroy final destination

Assert:

- delivery removed
- shadow removed
- TagFollow removed
- parity true

### 9. Account isolation

Trying to update/destroy another account's compatibility ID returns not found
and changes nothing.

### 10. Missing shadow fails closed

Construct canonical-only delivery with a compatibility ID but no follow_tags row.

Update/destroy must fail without changing canonical state.

Do not auto-repair silently in this stage.

### 11. API-created row remains Settings-compatible

Create through the new canonical API writer.

Then GET Settings edit using returned compatibility ID.

Expected:

- legacy FollowTag shadow exists
- existing Settings edit action loads it successfully

This proves rollback/form compatibility.

### 12. Legacy Settings-created row remains API-mutable

Create through normal FollowTag/Settings-style legacy path so U3a mirrors it.

Then update or destroy it through the new canonical API writer.

Expected:

- canonical write succeeds
- shadow remains synchronized
- subsequent canonical read is correct

This proves coexistence of both mutation directions during the transition.

## Parity as a test oracle

After successful create/update/destroy/move scenarios, run:

    HashtagUnification::FollowTagParity.new.call

and assert:

    ok == true
    management_ready == true

For tests intentionally creating inconsistent sentinels, isolate or repair them
before asserting global parity.

Do not change parity semantics in this PR.

## Timestamps

The canonical TagFollowDelivery updated_at is the API-visible timestamp.

Keep the legacy shadow timestamps close/equivalent enough for rollback.

Recommended:

- create shadow timestamps from the canonical delivery created_at/updated_at
- after canonical update, set shadow updated_at from delivery.updated_at
- preserve shadow created_at on update

Do not make timestamp parity a new FollowTagParity requirement.

## Rate-limit behavior

Do not change API authorization/rate-limit behavior beyond replacing the storage
writer.

The current /api/v1/follow_tags controller does not explicitly request
FollowTag rate_limit: true. Do not invent a new limit in this PR.

## No schema migration

U3b-3c should require no schema migration.

The compatibility ID column/index already exists.

## Durable documentation

Update:

    docs/hashtag-subsystem-upstream-unification.md

Record:

- U3b-3c makes compatibility API create/update/destroy canonical
- legacy follow_tags becomes a synchronized rollback shadow for this API path
- Settings and standard TagsController still write legacy FollowTag
- the old follow_tags sequence remains the shared compatibility-ID allocator
  while any legacy writer remains active
- no second sequence is introduced
- API writer bypasses FollowTag callbacks when maintaining the shadow
- rollback remains application-code-only because shadow parity is maintained
- U3b-3d will handle Settings form/write cutover

## Deployment gate

Immediately before deploy:

    RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity

Require:

    ok: true
    management_ready: true

After deploy, canary:

1. API create a temporary Home follow
2. verify GET index/show same ID
3. verify Settings edit URL using that ID opens
4. API update name/media_only and verify canonical read
5. optionally edit the same resource through Settings legacy path and verify API
   canonical read reflects the mirrored result
6. API delete
7. verify resource disappears from API/Settings
8. rerun parity
9. require ok: true and management_ready: true

## Suggested production files

Expected:

- app/services/hashtag_unification/tag_follow_delivery_writer.rb
- app/controllers/api/v1/follow_tags_controller.rb
- docs/hashtag-subsystem-upstream-unification.md

Potentially small model helpers if genuinely useful.

Avoid unrelated model association cleanup in this PR.

## Suggested specs

Add:

- spec/services/hashtag_unification/tag_follow_delivery_writer_spec.rb

Extend:

- spec/controllers/api/v1/follow_tags_controller_spec.rb

Reuse existing Settings controller specs for the API-created -> legacy edit seam
if convenient.

Run all previous U3 regression sets.

## Validation commands

Focused U3b-3c:

    RAILS_ENV=test bundle exec rspec       spec/services/hashtag_unification/tag_follow_delivery_writer_spec.rb       spec/controllers/api/v1/follow_tags_controller_spec.rb       spec/controllers/settings/follow_tags_controller_spec.rb       spec/serializers/rest/follow_tag_serializer_spec.rb

U3b-3a:

    RAILS_ENV=test bundle exec rspec       spec/models/tag_follow_delivery_spec.rb       spec/services/hashtag_unification/follow_tag_backfill_spec.rb       spec/services/hashtag_unification/follow_tag_mirror_spec.rb       spec/services/hashtag_unification/follow_tag_parity_spec.rb       spec/models/follow_tag_spec.rb

U3b-2:

    RAILS_ENV=test bundle exec rspec       spec/services/fan_out_on_write_service_hashtag_follow_spec.rb       spec/lib/feed_manager_hashtag_follow_spec.rb

U3b-1:

    RAILS_ENV=test bundle exec rspec       spec/controllers/api/v1/followed_tags_controller_spec.rb       spec/presenters/tag_relationships_presenter_spec.rb       spec/serializers/rest/tag_serializer_spec.rb       spec/controllers/api/v1/tags_controller_spec.rb

Note: #131's reported regression command omitted
spec/controllers/api/v1/tags_controller_spec.rb. Include it in this run.

Run RuboCop on every modified Ruby file.

## Cursor completion protocol

When implementation is complete:

1. run focused U3b-3c specs
2. rerun U3b-3a / U3b-2 / U3b-1 including tags_controller_spec
3. run RuboCop
4. update durable architecture documentation
5. delete:
   docs/development/u3b3c-canonical-api-write-cutover-cursor-task.md
6. add a PR comment with:
   - final head SHA
   - exact production files changed
   - writer service API
   - compatibility-ID allocation mechanism
   - shadow synchronization mechanism
   - lock/concurrency strategy
   - exact RSpec commands/results
   - exact RuboCop result
   - any unrelated failures separately identified

Do not merge.

ChatGPT will review the final implementation and validation.

## Acceptance criteria

U3b-3c is ready when:

- API create/update/destroy mutate TagFollowDelivery canonically
- API controller does not save/destroy FollowTag
- new IDs come from the existing follow_tags sequence via shadow insert
- no independent compatibility-ID sequence exists
- legacy shadow is synchronized atomically without callbacks
- compatibility ID is preserved across updates/tag movement
- peer destinations remain independent
- final-destination removal deletes the TagFollow relation
- update collisions roll back
- account isolation holds
- missing shadow fails closed
- API mutations work with FollowTagMirror disabled
- API-created rows remain editable through legacy Settings
- legacy-created rows remain mutable through canonical API
- parity remains ok: true / management_ready: true after successful mutations
- no schema migration
- no standard TagsController or Settings write cutover
- U3b-3a/U3b-2/U3b-1 regressions are green
- no new RuboCop offenses
- handoff markdown is removed before final review
