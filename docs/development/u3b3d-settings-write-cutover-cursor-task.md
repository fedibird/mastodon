# Cursor task: U3b-3d Settings form/write canonical cutover

## Purpose

Implement U3b-3d of the hashtag subsystem upstream-unification project.

Current production architecture after U3b-3c:

- standard relation reads use TagFollow
- FanOut / FeedManager destination reads use TagFollowDelivery
- management API index/show use TagFollowDelivery
- management API create/update/destroy use TagFollowDeliveryWriter
- Settings index reads TagFollowDelivery
- Settings new/create/edit/update/destroy still use legacy FollowTag
- standard Api::V1::TagsController follow/unfollow still uses FollowTag
- FollowTag writes still mirror through U3a
- canonical API writes keep follow_tags as an exact callback-free rollback shadow
- compatibility IDs come from the existing follow_tags primary-key sequence
- production parity gate remains:
  - ok: true
  - management_ready: true

U3b-3d cuts the Settings form/write surface over to canonical TagFollowDeliveryWriter.

After this PR, the only intended remaining normal legacy writer in this subsystem is standard Api::V1::TagsController follow/unfollow.

## Core goal

Settings must no longer save, update, or destroy FollowTag Active Record objects.

The Settings flow becomes:

    Settings index/edit read
      -> TagFollowDelivery

    Settings create/update/destroy
      -> HashtagUnification::TagFollowDeliveryWriter
      -> TagFollow / TagFollowDelivery
      -> callback-free follow_tags rollback shadow

The legacy shadow remains because standard TagsController still writes FollowTag and because rollback is still required.

## Form model

Introduce a small Settings form adapter:

    Form::FollowTag

Use the repository's existing Form::* pattern.

Recommended shape:

    class Form::FollowTag
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :integer
      attribute :name, :string
      attribute :list_id, :integer
      attribute :media_only, :boolean, default: false

      validates :name, presence: true

      def self.model_name
        ::FollowTag.model_name
      end

      def persisted?
        id.present?
      end
    end

Equivalent clear implementation is acceptable.

Important reasons for reusing FollowTag.model_name:

- preserve existing follow_tag[...] parameter key
- preserve current SimpleForm/I18n labels
- avoid changing external HTML form parameter shape unnecessarily

Do not make the form model write FollowTag.

A small constructor such as from_delivery(delivery) is encouraged:

    id         = delivery.legacy_resource_id
    name       = delivery.name
    list_id    = delivery.list_id
    media_only = delivery.media_only

## Settings read authority

Index is already canonical from U3b-3b.

Change edit loading to canonical too.

GET /settings/follow_tags/:id/edit must:

- scope TagFollowDelivery through current_account
- lookup by legacy_follow_tag_id
- not lookup by TagFollowDelivery.id
- build Form::FollowTag from the canonical delivery

The legacy shadow must not be the display source for edit.

This pins canonical read authority across both index and edit.

## New action

GET new should build:

    Form::FollowTag.new

not current_account.follow_tags.build.

Keep the same view/layout behavior.

## Create action

POST Settings create must use TagFollowDeliveryWriter#create!.

Inputs:

- name
- list_id
- media_only

The writer already supports optional List destination.

### list_id semantics

Preserve existing Settings behavior exactly:

- nil / blank -> Home
- existing list id -> that current account List
- -1 -> create/find a List for current_account with title == submitted hashtag name

Resolve an existing list through current_account ownership.

Do not permit selecting another account's List.

The old helper returns Home as nil and “new list” as -1; preserve that UI contract.

### create success

On success redirect to settings_follow_tags_path as before.

### create failure

Re-render the existing Settings page with the form object and canonical index collection populated.

Preserve user-entered values.

Map validation failures onto the form object's errors sufficiently for shared/error_messages to display a useful message.

At minimum cover:

- blank/invalid name
- duplicate destination

Do not convert application validation failures into 500s.

Do not create FollowTag through Active Record.

## Update action

PUT/PATCH Settings /settings/follow_tags/:id must:

1. resolve canonical delivery for current_account by legacy_follow_tag_id
2. build/use Form::FollowTag
3. resolve submitted destination List
4. call TagFollowDeliveryWriter#update! with:
   - account
   - legacy_resource_id
   - name
   - list
   - media_only
5. preserve the same compatibility ID
6. redirect to index on success

This is the first production caller that should exercise writer destination movement between:

- Home -> List
- List -> Home
- List A -> List B

The writer already supports list:.

### collision behavior

If moving would collide with an existing destination for the target account/tag/list:

- mutation must fully roll back
- render edit with useful form error
- do not mutate rollback shadow

## Destroy action

DELETE Settings /settings/follow_tags/:id must call:

    TagFollowDeliveryWriter#destroy!

using current_account and the legacy resource ID.

It must not call FollowTag#destroy!.

Peer destination semantics remain:

- deleting Home leaves Lists
- deleting one List leaves Home/other Lists
- final destination removes TagFollow

Redirect to Settings index on success as before.

## Corrupt/missing rollback shadow

Production management_ready guarantees source-backed resources have a rollback shadow.

Still fail closed.

If writer raises InconsistentLegacyShadowError:

- do not partially mutate canonical state
- return a safe HTML failure rather than 500
- update/create should preferably attach a base form error and re-render
- destroy may use the existing 422 HTML error response if that is cleaner

Do not silently recreate a missing shadow in this stage.

## Error propagation

The form adapter should remain a presentation/input model, not duplicate all canonical validations.

A practical controller helper may copy errors from ActiveRecord::RecordInvalid:

    error.record.errors.full_messages.each do |message|
      @follow_tag.errors.add(:base, message)
    end

For invalid Tag/name errors, mapping to :name is preferable if straightforward.

The exact shape is flexible, but the user must see an error and the request must not 500.

## Views

Preserve existing visual behavior.

Recommended variable name can remain @follow_tag for minimal template churn even though it is now Form::FollowTag.

Existing views:

- index.html.haml
- new.html.haml
- edit.html.haml
- _fields.html.haml

should require minimal changes.

Because Form::FollowTag.model_name maps to FollowTag, simple_form should continue posting follow_tag[...] params and using existing label translations.

Routes remain explicit as they already are.

Do not override TagFollowDelivery#to_param.

## Settings index row links

Already canonical and explicitly use legacy_resource_id from U3b-3b.

Keep that behavior.

## Strong write-authority sentinel

As with U3b-3c, prove Settings writes do not depend on U3a.

Stub:

    HashtagUnification::FollowTagMirror

to raise if instantiated, then exercise Settings:

- create
- update
- destroy

Expected:

- operations succeed through TagFollowDeliveryWriter
- rollback shadow remains synchronized
- no FollowTag callback/mirror path is invoked

This is mandatory.

## Read-source sentinels

### Edit canonical-only positive

Create:

    TagFollow + TagFollowDelivery
    valid legacy_follow_tag_id
    no FollowTag shadow

GET edit should render the canonical data.

This proves edit reads canonical, not legacy.

Do not attempt a mutation in this sentinel because writer correctly requires the rollback shadow.

### Legacy-only negative

Create FollowTag via callback-bypassing insert with no canonical row.

GET edit by that ID must return not found.

This proves edit no longer reads FollowTag.

Index negative sentinel already exists but should remain green.

## Required regression matrix

### 1. New form

GET new:

- renders successfully
- form object is Form::FollowTag
- Home/default media_only behavior remains sensible
- parameter key remains follow_tag

### 2. Create Home

POST Settings create with Home.

Assert:

- canonical TagFollow/TagFollowDelivery created
- rollback shadow created with same compatibility ID
- Settings index shows it
- FollowTagMirror disabled
- parity ok: true
- management_ready: true

### 3. Create List destination

POST with owned existing list id.

Assert canonical/list/shadow data match.

### 4. Create new List via -1

POST list_id=-1.

Assert:

- list is found/created for current account
- delivery points to it
- shadow points to it
- existing behavior/title is preserved

### 5. Reject foreign List

Submitting another account's list id must not create/move a destination.

Use 404/validation behavior consistent with controller conventions, but never mutate another account's List destination.

### 6. Duplicate destination

Attempt duplicate Home or same concrete List.

Assert:

- form re-renders with error
- no extra canonical or shadow row
- parity remains true

### 7. Edit canonical-only

GET edit canonical-only/no FollowTag shadow.

Assert canonical values populate the form.

### 8. Edit does not resolve canonical PK

Use delivery.id != legacy_follow_tag_id.

GET edit with canonical PK must not resolve unless it coincidentally equals a compatibility ID.

### 9. Update media_only

Settings update through writer.

Assert same compatibility ID, canonical + shadow synchronized, mirror disabled.

### 10. Move Home -> List

Assert:

- same delivery resource / compatibility ID
- list_id changes
- shadow matches
- no stale Home
- parity true

### 11. Move List -> Home

This specifically exercises the Home uniqueness fix from PR #129.

Assert succeeds when no Home peer exists and preserves compatibility ID.

### 12. Move List A -> List B

Assert destination movement and shadow sync.

### 13. Move collision

For example Home -> a target relation/destination already present, or List A -> List B already present.

Assert render error and complete rollback.

### 14. Rename tag while moving/keeping destination

Settings allows name edits.

Assert writer preserves compatibility ID and moves relation correctly.

Cover parent TagFollow cleanup when old relation becomes empty.

### 15. Destroy peer destination

Home + List:

delete one Settings row.

Assert peer survives.

### 16. Destroy final destination

Assert TagFollow + delivery + shadow removed.

### 17. API-created -> Settings update/destroy

Create through canonical API/writer, then update or destroy through Settings.

Proves both canonical callers share the same writer/resource semantics.

### 18. Legacy standard/FollowTag-created -> Settings canonical mutation

Create via normal FollowTag so U3a mirrors it.

Then update/destroy through Settings writer.

Proves remaining legacy writer interop.

### 19. Account isolation

Edit/update/destroy another account's compatibility ID must not resolve/mutate.

### 20. Missing shadow fail closed

Canonical destination with compatibility ID but no shadow:

- GET edit may render canonical data
- PUT/DELETE must fail safely
- canonical state unchanged

## Parity as oracle

After successful create/update/move/destroy scenarios, assert:

    HashtagUnification::FollowTagParity.new.call

returns:

    ok: true
    management_ready: true

Do not change parity semantics.

## Controller cleanup target

After U3b-3d, Settings::FollowTagsController should not use:

    current_account.follow_tags.build
    current_account.follow_tags.new
    current_account.follow_tags.find
    @follow_tag.save
    @follow_tag.update
    @follow_tag.destroy!

for normal actions.

It may refer to the FollowTag constant only indirectly through Form::FollowTag.model_name or test/rollback context.

The controller should use canonical lookup + TagFollowDeliveryWriter.

## Standard TagsController remains legacy

Do NOT modify:

    Api::V1::TagsController

in this PR.

Its follow/unfollow behavior has a separate multi-destination semantic question and should be cut over deliberately in the next stage.

This is important: do not collapse U3b-3d and standard Mastodon follow/unfollow write semantics.

## U3a remains

Do not remove U3a mirror yet.

Standard TagsController still writes FollowTag, so the mirror remains necessary.

Do not invert or delete FollowTag callbacks.

## No schema migration

No schema changes are expected.

Do not change the compatibility-ID allocator.

The existing follow_tags sequence remains shared because standard TagsController is still a legacy writer.

## Durable documentation

Update:

    docs/hashtag-subsystem-upstream-unification.md

Record:

- U3b-3d cuts Settings edit/new/create/update/destroy away from FollowTag as an authoritative model
- Settings uses Form::FollowTag for input/presentation
- edit values come from canonical TagFollowDelivery
- Settings mutations call TagFollowDeliveryWriter
- follow_tags remains callback-free rollback shadow for canonical writes
- standard TagsController remains the only intended normal legacy writer
- U3a therefore remains required
- existing follow_tags sequence remains compatibility-ID allocator
- next stage must separately resolve standard follow/unfollow semantics with multiple destinations
- rollback remains application-code-only because the writer keeps shadow parity

## Deployment gate

Immediately before deployment:

    RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity

Require:

    ok: true
    management_ready: true

After deployment canary through the actual Settings UI:

1. open existing Home and List edits
2. create temporary Home follow
3. create/move a temporary List follow
4. move List -> Home if practical
5. rename and toggle media_only
6. verify same URL/resource ID persists
7. optionally verify API GET shows the same canonical data
8. delete temporary destinations
9. rerun parity
10. require ok: true and management_ready: true

## Suggested production files

Expected:

- app/models/form/follow_tag.rb
- app/controllers/settings/follow_tags_controller.rb
- app/views/settings/follow_tags/new.html.haml
- app/views/settings/follow_tags/edit.html.haml
- possibly index.html.haml only if form variable wiring requires it
- docs/hashtag-subsystem-upstream-unification.md

TagFollowDeliveryWriter should preferably require little or no change. If Settings exposes a real writer gap, fix it with focused regression coverage rather than duplicating mutation logic in the controller.

## Validation

Focused U3b-3d:

    RAILS_ENV=test bundle exec rspec       spec/models/form/follow_tag_spec.rb       spec/controllers/settings/follow_tags_controller_spec.rb       spec/services/hashtag_unification/tag_follow_delivery_writer_spec.rb

U3b-3c API:

    RAILS_ENV=test bundle exec rspec       spec/controllers/api/v1/follow_tags_controller_spec.rb       spec/serializers/rest/follow_tag_serializer_spec.rb

U3b-3a:

    RAILS_ENV=test bundle exec rspec       spec/models/tag_follow_delivery_spec.rb       spec/services/hashtag_unification/follow_tag_backfill_spec.rb       spec/services/hashtag_unification/follow_tag_mirror_spec.rb       spec/services/hashtag_unification/follow_tag_parity_spec.rb       spec/models/follow_tag_spec.rb

U3b-2:

    RAILS_ENV=test bundle exec rspec       spec/services/fan_out_on_write_service_hashtag_follow_spec.rb       spec/lib/feed_manager_hashtag_follow_spec.rb

U3b-1 / standard-write sentinel:

    RAILS_ENV=test bundle exec rspec       spec/controllers/api/v1/followed_tags_controller_spec.rb       spec/presenters/tag_relationships_presenter_spec.rb       spec/serializers/rest/tag_serializer_spec.rb       spec/controllers/api/v1/tags_controller_spec.rb

Run RuboCop on every modified Ruby file.

## Cursor completion protocol

When implementation is complete:

1. run focused U3b-3d specs
2. rerun all U3b-3c/U3b-3a/U3b-2/U3b-1 regressions
3. run RuboCop
4. update durable architecture docs
5. delete:
   docs/development/u3b3d-settings-write-cutover-cursor-task.md
6. add PR comment with:
   - final head SHA
   - production files changed
   - Form::FollowTag contract
   - canonical edit lookup behavior
   - list_id / -1 handling
   - Settings writer calls
   - error/fail-closed behavior
   - exact RSpec commands/results
   - exact RuboCop result
   - unrelated failures separately identified

Do not merge.

ChatGPT will review the final implementation.

## Acceptance criteria

U3b-3d is ready when:

- Settings new/edit use Form::FollowTag
- edit data is loaded from TagFollowDelivery, not FollowTag
- create/update/destroy use TagFollowDeliveryWriter
- Settings controller no longer saves/destroys FollowTag
- follow_tag[...] form parameter compatibility is preserved
- existing label/view behavior is preserved
- Home/List/new-List behavior is preserved
- foreign List injection is prevented
- compatibility ID stays stable through edits/moves
- Home/List peer semantics remain intact
- List -> Home works
- collisions fully roll back and display errors
- missing shadow fails closed without 500/partial mutation
- FollowTagMirror-disabled Settings mutations succeed
- canonical-only edit is visible
- legacy-only callback-bypass edit is not visible
- API-created rows are Settings-mutable
- legacy-created rows are Settings-mutable
- parity remains ok: true / management_ready: true after successful operations
- standard TagsController remains unchanged
- U3a remains unchanged
- no schema migration
- all U3 regressions are green
- no new RuboCop offenses
- handoff markdown removed before final review
