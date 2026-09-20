# Cursor task: U3b-3b management read cutover

## Purpose

Implement U3b-3b of the hashtag subsystem upstream-unification project.

Current production state:

- U3a: legacy FollowTag writes synchronously mirror into TagFollow + TagFollowDelivery
- U3b-1: standard hashtag-follow relation reads use TagFollow
- U3b-2: FanOut and FeedManager destination reads use TagFollowDelivery
- U3b-3a: TagFollowDelivery carries nullable unique legacy_follow_tag_id, populated by backfill/mirror
- production parity has been confirmed:
  - ok: true
  - management_ready: true

U3b-3b cuts the Fedibird destination-management **read surfaces** over to canonical TagFollowDelivery while retaining legacy FollowTag as the write authority.

## Core rule

Canonical internal identity and external compatibility identity are different:

    TagFollowDelivery.id
      = internal canonical primary key

    TagFollowDelivery.legacy_follow_tag_id
      = external compatibility resource ID historically exposed as follow_tags.id

Never expose TagFollowDelivery.id through the existing Fedibird management API or Settings URLs.

Do not change old resource URLs.

## Scope

Cut these read surfaces to TagFollowDelivery:

1. API GET /api/v1/follow_tags
2. API GET /api/v1/follow_tags/:id
3. Settings /settings/follow_tags index/listing

Keep these write/form surfaces on FollowTag:

- API POST /api/v1/follow_tags
- API PUT/PATCH /api/v1/follow_tags/:id
- API DELETE /api/v1/follow_tags/:id
- Settings new/create
- Settings edit form object and GET edit
- Settings update
- Settings destroy

This intentionally creates a transitional split:

    reads/listing/show -> canonical TagFollowDelivery
    mutations/forms    -> legacy FollowTag -> U3a mirror

## Why Settings edit stays legacy

The current edit form is a SimpleForm resource bound to FollowTag and submits follow_tag params.

Switching edit form objects to TagFollowDelivery would mix read cutover with write-authority and form-model changes.

U3b-3b should therefore make only the index/listing canonical. Existing edit/delete links must still use legacy_follow_tag_id so they resolve to the legacy FollowTag write resource.

A later U3b-3c can cut write/form authority over cleanly.

## TagFollowDelivery presentation support

TagFollowDelivery already delegates account/tag identity through TagFollow.

Add only the minimal presentation support required by the existing API/view, for example:

    delegate :name, to: :tag

Use allow_nil only if consistent with existing model conventions; tag_follow/tag are required in valid canonical rows.

Do not add broad FollowTag compatibility behavior to the model.

Do not override to_param.

That is important: to_param should not blur canonical PK and legacy external ID.

## Explicit compatibility ID accessor

Add a small explicit method for external resource identity, recommended shape:

    def legacy_resource_id
      legacy_follow_tag_id || raise(ActiveRecord::RecordNotFound)
    end

Equivalent fail-closed behavior is acceptable.

Requirements:

- never fall back to TagFollowDelivery.id
- never serialize a blank ID
- never silently hide the distinction between canonical PK and compatibility ID

This method should be used by the serializer and Settings link generation.

If you choose a different name, keep it explicit and historical/compatibility-oriented.

## REST::FollowTagSerializer

The serializer must work during the transition with two object types:

- FollowTag for create/update responses
- TagFollowDelivery for canonical index/show responses

Preserve the existing JSON shape exactly:

    id
    name
    updated_at

No new fields.

ID behavior:

    FollowTag
      -> object.id

    TagFollowDelivery
      -> object.legacy_resource_id

Both must serialize as strings as before.

Name behavior should continue to return the hashtag name with no Tag identity/display_name change.

Do not add list_id or media_only to this serializer in this PR.

## Api::V1::FollowTagsController

Split read and write loading clearly.

Recommended structure:

    before_action :set_follow_tag_delivery, only: :show
    before_action :set_follow_tag, only: [:update, :destroy]

Index:

    canonical TagFollowDelivery rows belonging to current_account

Show:

    canonical TagFollowDelivery lookup belonging to current_account
    by legacy_follow_tag_id == params[:id]

Update/destroy:

    legacy FollowTag lookup belonging to current_account
    by primary key params[:id]

Create:

    unchanged legacy FollowTag.create!

### Canonical account scope

Use the TagFollow relation for account ownership.

Conceptually:

    TagFollowDelivery
      .joins(:tag_follow)
      .merge(TagFollow.where(account: current_account))

Preload tag data as needed to avoid N+1 in serialization.

### Show ID rule

GET /api/v1/follow_tags/:id must interpret :id as legacy_follow_tag_id.

It must NOT accept TagFollowDelivery.id as a fallback.

If a canonical PK happens to differ from the compatibility ID, only the compatibility ID is a valid external lookup.

### Authorization/isolation

A user must not be able to GET another account's canonical delivery by knowing its legacy_follow_tag_id.

Scope by current_account before matching compatibility ID.

## Settings index

Change only set_follow_tags / index collection to canonical TagFollowDelivery.

Preserve current ordering semantics:

    Home first (list_id NULLS FIRST)
    then updated_at

Keep existing page size:

    per(40)

Preload:

- list
- tag_follow -> tag

The view can keep the collection variable name @follow_tags for minimal churn.

### Settings row partial

The existing row partial needs:

- name
- media_only
- list_id
- list.title
- edit URL
- delete URL

All data except URL identity exists on TagFollowDelivery after minimal delegation.

Change edit/delete paths to pass the explicit compatibility ID, not the object itself:

    edit_settings_follow_tag_path(follow_tag.legacy_resource_id)
    settings_follow_tag_path(follow_tag.legacy_resource_id)

Do not rely on to_param.

The edit and destroy actions remain legacy and therefore continue to resolve the same historical ID.

## Important transition invariant

For a normal source-backed row:

    FollowTag.id == TagFollowDelivery.legacy_follow_tag_id

So this sequence must work unchanged:

    Settings index reads TagFollowDelivery
      -> link contains legacy ID 123
      -> GET /settings/follow_tags/123/edit
      -> legacy FollowTag.find(123)
      -> existing form works

Likewise API:

    POST /api/v1/follow_tags
      -> creates FollowTag id 123
      -> U3a mirrors canonical delivery with legacy_follow_tag_id 123
      -> response id "123"

    GET /api/v1/follow_tags/123
      -> reads canonical TagFollowDelivery by legacy_follow_tag_id
      -> response id "123"

## Read-source sentinel requirements

### API positive sentinel

Create canonical-only data directly:

    TagFollow
    TagFollowDelivery(legacy_follow_tag_id: some_unused_id)
    no FollowTag

GET index and GET show must return it.

This proves API reads canonical data.

### API negative sentinel

Create a callback-bypassing FollowTag row only:

    FollowTag exists
    no TagFollow / TagFollowDelivery

GET index must not return it.

GET show by that legacy row ID must return not found.

Do not run mirror in this sentinel.

### Settings positive sentinel

Create canonical-only delivery with a compatibility ID.

GET Settings index must display:

- tag name
- destination
- media_only state as applicable
- edit/delete link using legacy_follow_tag_id

### Settings negative sentinel

Create callback-bypassing legacy-only FollowTag.

Settings index must not show it.

This proves Settings list reads canonical data.

## Canonical ID leakage regression

Use deliberately different values:

    delivery.id != delivery.legacy_follow_tag_id

Verify:

- API JSON id equals legacy_follow_tag_id, not delivery.id
- API show resolves by legacy_follow_tag_id
- API show with delivery.id does not resolve unless by coincidence it equals an actual compatibility ID
- Settings edit/delete links contain legacy_follow_tag_id, not delivery.id

Avoid flaky coincidence by choosing a clearly unused compatibility ID such as current FollowTag maximum + a safe offset, while respecting the unique index.

## Normal bridge regression

Test the real transitional path.

### API create -> canonical show

1. POST create through existing API write path
2. assert FollowTag exists
3. assert U3a canonical delivery exists with matching legacy_follow_tag_id
4. GET show by returned ID
5. assert show is served from canonical data and shape remains identical

A useful way to prove step 5 is to mutate a presentation-safe canonical timestamp after mirror, or otherwise use a sentinel that distinguishes canonical source without changing contract. Do not introduce brittle implementation spies unless necessary.

### API update

Keep PUT/PATCH write path legacy.

Verify:

1. update legacy resource through API
2. U3a updates canonical destination
3. subsequent GET show reflects canonical mirrored state
4. ID remains unchanged

Because serializer currently exposes only id/name/updated_at, choose a field/observable that is actually part of the contract. Do not add API fields just for testing.

### API destroy

1. DELETE legacy resource
2. U3a removes canonical delivery/relation as appropriate
3. subsequent GET show returns not found

## Settings bridge regression

For a normal FollowTag created through Active Record:

1. U3a mirror creates canonical delivery
2. Settings index lists canonical row
3. edit link uses source FollowTag.id
4. GET edit by that ID still succeeds using legacy FollowTag

This pins the read/write seam.

## Missing compatibility ID behavior

Production gate guarantees source-backed rows have compatibility IDs.

Still pin fail-closed behavior so a corrupted canonical row with nil legacy_follow_tag_id never leaks TagFollowDelivery.id.

Acceptable outcomes include:

- explicit RecordNotFound/error before generating an external ID

Do not silently substitute canonical id.

Do not filter such rows out in a way that makes parity/runtime corruption invisible unless there is a compelling project convention; fail-closed is preferred.

## No schema migration

U3b-3b requires no schema migration.

legacy_follow_tag_id foundation is already merged and production-backfilled.

## Explicitly out of scope

Do not change:

- FollowTag write callbacks
- FollowTagMirror direction
- FollowTagBackfill
- FollowTagParity semantics
- Api::V1::TagsController standard follow/unfollow
- FanOut
- FeedManager
- Tag identity/display_name
- Account/Tag associations broadly
- old table removal
- direct canonical create/update/destroy authority
- Settings form model
- resource routes

Do not delete FollowTag.

## Durable documentation

Update docs/hashtag-subsystem-upstream-unification.md.

Record that U3b-3b changes:

Canonical management reads:
- API follow_tags index/show
- Settings follow-tags index

Still legacy writes/forms:
- API create/update/destroy
- Settings new/create/edit/update/destroy

Record explicitly:

- all existing outward IDs remain legacy_follow_tag_id
- canonical TagFollowDelivery.id is internal only
- no to_param override is used
- management_ready true is a deployment prerequisite
- rollback is application-code-only because legacy writes/table remain intact

## Deployment gate

Before deployment run:

    RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity

Require:

    ok: true
    management_ready: true

After deployment perform a canary:

1. open Settings hashtag-follow list
2. confirm existing Home/List rows and edit links
3. GET /api/v1/follow_tags and a specific existing ID
4. create one temporary follow via legacy management path
5. confirm it appears in canonical GET/list
6. update/move it if practical
7. confirm same ID remains
8. delete it
9. confirm it disappears
10. rerun parity and require both gates true

## Suggested files

Production:

- app/models/tag_follow_delivery.rb
- app/serializers/rest/follow_tag_serializer.rb
- app/controllers/api/v1/follow_tags_controller.rb
- app/controllers/settings/follow_tags_controller.rb
- app/views/settings/follow_tags/_follow_tag.html.haml

Tests likely need new focused files:

- spec/controllers/api/v1/follow_tags_controller_spec.rb
- spec/controllers/settings/follow_tags_controller_spec.rb
- spec/serializers/rest/follow_tag_serializer_spec.rb if useful

Prefer controller/request coverage that proves actual read source and ID behavior.

## Validation

Run focused U3b-3b specs.

Then rerun U3b-3a:

    RAILS_ENV=test bundle exec rspec       spec/models/tag_follow_delivery_spec.rb       spec/services/hashtag_unification/follow_tag_backfill_spec.rb       spec/services/hashtag_unification/follow_tag_mirror_spec.rb       spec/services/hashtag_unification/follow_tag_parity_spec.rb       spec/models/follow_tag_spec.rb

Rerun U3b-2:

    RAILS_ENV=test bundle exec rspec       spec/services/fan_out_on_write_service_hashtag_follow_spec.rb       spec/lib/feed_manager_hashtag_follow_spec.rb

Rerun U3b-1:

    RAILS_ENV=test bundle exec rspec       spec/controllers/api/v1/followed_tags_controller_spec.rb       spec/presenters/tag_relationships_presenter_spec.rb       spec/serializers/rest/tag_serializer_spec.rb       spec/controllers/api/v1/tags_controller_spec.rb

Run RuboCop on every modified Ruby file.

## Cursor completion protocol

When complete:

1. run focused U3b-3b specs
2. rerun U3b-3a/U3b-2/U3b-1 regressions
3. run RuboCop
4. update durable architecture docs
5. delete docs/development/u3b3b-management-read-cutover-cursor-task.md
6. add a PR comment with:
   - final head SHA
   - exact production files changed
   - API read/write split
   - Settings read/write split
   - explicit ID behavior
   - exact RSpec commands/results
   - exact RuboCop result
   - unrelated failures separately identified

Do not merge.

ChatGPT will review final diff and validation.

## Acceptance criteria

- API follow_tags index reads TagFollowDelivery
- API follow_tags show reads TagFollowDelivery by legacy_follow_tag_id
- API create/update/destroy remain FollowTag writes
- Settings index reads TagFollowDelivery
- Settings edit/update/destroy remain FollowTag
- existing outward IDs remain unchanged
- canonical TagFollowDelivery.id is never exposed as compatibility ID
- no to_param override
- canonical-only sentinels are visible in read surfaces
- legacy-only callback-bypass sentinels are invisible
- normal legacy writes appear immediately through U3a mirror
- delete removes canonical read resource
- missing compatibility ID fails closed
- no schema migration
- U3b-3a/U3b-2/U3b-1 regressions remain green
- no new RuboCop offenses
- handoff markdown removed before final review
