# Cursor task: U3b-1 TagFollow read cutover

## Purpose

Implement U3b-1 of the hashtag subsystem upstream-unification project.

U3a is already deployed and production-validated on fedibird.com:

- legacy `FollowTag` remains authoritative for writes
- normal Active Record `FollowTag` writes synchronously mirror into `TagFollow` + `TagFollowDelivery`
- production parity is `ok: true`
- Home and List destinations have been confirmed to dual-write correctly

U3b-1 is intentionally a **read-only cutover**.

The goal is to make the upstream-compatible `TagFollow` relation authoritative for standard hashtag-follow read semantics, while keeping all write paths and delivery routing on legacy `FollowTag` for rollback safety.

## Upstream reference

Use Mastodon `stable-4.2` as the behavioral reference.

Reference checked during design:

- branch: `mastodon/mastodon stable-4.2`
- commit at design time: `7a4a27c7fef37016f8cefcb7ca50d86c2b0c30a5`

Relevant upstream files:

- `app/controllers/api/v1/followed_tags_controller.rb`
- `app/presenters/tag_relationships_presenter.rb`
- `app/serializers/rest/tag_serializer.rb`
- `app/models/tag_follow.rb`

Do not blindly copy unrelated 4.2 changes. This task is limited to read semantics.

## Core invariant

Fedibird extends one canonical hashtag-follow relation with explicit delivery destinations:

```text
TagFollow
  account_id
  tag_id
  UNIQUE(account_id, tag_id)

TagFollowDelivery
  tag_follow_id
  list_id nullable   # nil = Home, N = List N
  media_only
```

Critical invariant:

```text
TagFollow exists != Home delivery exists
```

Home and Lists are peer destinations.

Therefore a List-only hashtag follow:

```text
TagFollow(account, tag)
  delivery(list_id = 123)
  no Home delivery
```

must still be represented by the **standard Mastodon API** as:

```json
"following": true
```

The standard relation says "this account follows this hashtag".

Fedibird destination-management APIs say where that relation is delivered.

Do not conflate those two concepts.

## U3b-1 scope

Switch these standard read surfaces from legacy `FollowTag` to canonical `TagFollow`:

1. `TagRelationshipsPresenter#following_map`
2. `REST::TagSerializer#following` fallback query
3. `Api::V1::FollowedTagsController#set_results`

Also bring the existing `FollowedTagsController` pagination plumbing into alignment with Mastodon 4.2 where it is currently obviously drifted/broken:

- authorization before_action should apply to the actual endpoint
- pagination after_action must run for `index`
- `records_continue?` must use `TAGS_LIMIT`, not undefined `TAG_LIMIT`
- pagination cursors should be based on `TagFollow#id`

## Explicitly out of scope

Do **not** change any of the following in U3b-1:

### Standard write path

Keep `Api::V1::TagsController` writes on legacy `FollowTag`:

```ruby
FollowTag.create!(...)
FollowTag.find_by(...)&.destroy!
```

U3a mirror must continue synchronizing those writes into `TagFollow`.

Do not switch POST follow or POST/DELETE unfollow to direct `TagFollow` writes yet.

Do not add `TagUnmergeWorker` merely because upstream 4.2 has it.

Do not add unrelated `cache_if_unauthenticated!` behavior.

### Fedibird destination management

Do not change:

- `Api::V1::FollowTagsController`
- `REST::FollowTagSerializer`
- Settings hashtag-follow UI/controllers
- List/Home destination editing
- `media_only` destination semantics

Those remain legacy row-oriented compatibility surfaces for now.

### Delivery / timeline behavior

Do not change:

- `FanOutOnWriteService`
- `FeedManager`
- hashtag fan-out queries
- `build_crutches`
- Home/List delivery admission

Those remain on legacy `FollowTag` until U3b-3.

### Tag identity

Do not change:

- `Tag#normalize`
- `HashtagNormalizer` behavior
- Tag collision/canonicalization
- `REST::TagSerializer#name`

In particular, upstream 4.2 uses:

```ruby
def name
  object.display_name
end
```

Fedibird intentionally has not cut over Tag identity yet. Leave the current raw-name behavior untouched.

### Tag model associations

Do not broaden this task by switching every `Tag` association from `FollowTag` to `TagFollow`.

Only change associations if a focused test proves they are required for these read surfaces. Prefer direct `TagFollow` queries matching upstream 4.2.

### TagFollowDelivery validation

Do not address the known Home partial-uniqueness model validator issue in this PR unless the implementation unexpectedly needs model-level delivery creation.

U3b-1 is read-only and should not need it.

## Required production-code changes

### 1. TagRelationshipsPresenter

Current Fedibird:

```ruby
FollowTag.select(:tag_id)
  .where(tag_id: tags.map(&:id), account_id: current_account_id)
```

Change this read to `TagFollow`, matching upstream 4.2 semantics.

The result remains one boolean per tag ID.

### 2. REST::TagSerializer#following

Current fallback query reads `FollowTag`.

Change only the following-state query to `TagFollow`.

Do not change serializer fields or tag name presentation.

With relationships supplied, continue using `TagRelationshipsPresenter#following_map`.

### 3. Api::V1::FollowedTagsController

Change the relation source:

```text
FollowTag -> TagFollow
```

Keep upstream-like:

```ruby
TagFollow.where(account: current_account)
  .joins(:tag)
  .eager_load(:tag)
  .to_a_paginated_by_id(...)
```

This intentionally changes Fedibird behavior from destination-row pagination to canonical relation pagination.

If a user follows one hashtag to:

```text
Home
List A
List B
```

the endpoint must return that hashtag **once**, not three times.

A List-only relation must also appear once.

### 4. FollowedTagsController pagination drift

Align the controller's pagination behavior with upstream 4.2.

Current Fedibird contains drift such as:

```ruby
after_action :insert_pagination_headers, only: :show
```

despite the controller exposing `index`, and:

```ruby
@results.size == limit_param(TAG_LIMIT)
```

despite the constant being `TAGS_LIMIT`.

Correct these while touching the controller.

Do not redesign the pagination mechanism beyond upstream 4.2 behavior.

## Important semantic change

Before U3b-1:

```text
GET /api/v1/followed_tags
  source = FollowTag destination rows
```

This can expose duplicate tags when one hashtag has multiple destinations.

After U3b-1:

```text
GET /api/v1/followed_tags
  source = TagFollow canonical relations
```

One account/tag relation appears exactly once.

This is intentional and is part of upstream convergence.

## Standard follow/unfollow bridge

Although U3b-1 does not modify `Api::V1::TagsController`, add regression coverage proving that the existing U3a bridge still makes standard API responses correct after the read cutover.

For a simple Home-only case:

### Follow

```text
POST /api/v1/tags/:id/follow
  -> creates legacy FollowTag Home row
  -> U3a synchronously mirrors TagFollow + Home delivery
  -> serializer now reads TagFollow
  -> response following == true
```

### Unfollow

```text
POST /api/v1/tags/:id/unfollow
  -> destroys legacy FollowTag
  -> U3a synchronously removes TagFollow when final destination disappears
  -> serializer now reads TagFollow
  -> response following == false
```

Do not use a multi-destination relation for this unfollow test.

The current legacy standard-unfollow behavior with multiple destinations is intentionally deferred to a later write-cutover stage; do not accidentally define or "fix" it in U3b-1.

## Required regression coverage

Add focused specs for the following.

### A. Presenter reads TagFollow

Prove `TagRelationshipsPresenter` reports following from `TagFollow`.

Prefer at least one test where the target relation exists independently of legacy `FollowTag`, so the test cannot pass accidentally through the old table.

Expected:

```text
TagFollow exists
FollowTag absent
=> following_map[tag.id] == true
```

### B. Serializer fallback reads TagFollow

For an authenticated/current-user serialization path without a prebuilt relationships presenter:

```text
TagFollow exists
FollowTag absent
=> following == true
```

If a lower-level serializer spec is awkward because of current_user injection, a focused request/controller spec that exercises the fallback path is acceptable.

### C. List-only relation is still "following"

Create a legacy List-only `FollowTag` through normal Active Record so U3a mirrors it.

Verify:

```text
TagFollow exists
TagFollowDelivery Home count == 0
TagFollowDelivery List count == 1
standard tag serializer following == true
GET /api/v1/followed_tags includes the tag
```

This is a critical Fedibird invariant.

### D. Multiple destinations deduplicate

Create the same account/tag with multiple legacy destinations, for example Home + List.

Let U3a mirror them.

Verify:

```text
one TagFollow
multiple TagFollowDelivery rows
GET /api/v1/followed_tags returns the tag once
```

### E. Read-source sentinel

Add at least one test that would fail if the implementation silently went back to `FollowTag`.

A useful pattern is a target-only relation:

```ruby
TagFollow.create!(account: account, tag: tag)
```

with no legacy source row.

Standard read surfaces should treat it as followed.

Optionally also add the inverse sentinel using callback-bypassing legacy insertion:

```text
legacy FollowTag exists
TagFollow absent
=> new read surface does not report following
```

Only do this if the test can be expressed cleanly without coupling to unrelated validation details.

The purpose is to prove which table is authoritative for reads.

### F. Followed-tags pagination

Exercise enough records with a small `limit` to prove:

- endpoint succeeds
- pagination header path actually runs on `index`
- no undefined `TAG_LIMIT`
- cursors come from TagFollow rows
- next/previous links are structurally valid according to existing API conventions

Use existing project pagination helpers/spec style where available.

### G. Standard follow/unfollow still works through dual-write

Simple Home-only relation:

- POST follow returns success
- legacy `FollowTag` exists
- canonical `TagFollow` exists
- response `following` is true

Then unfollow:

- legacy relation removed
- canonical relation removed
- response `following` is false

This guards the U3a/U3b-1 boundary.

## Suggested files

Production files expected to change:

- `app/controllers/api/v1/followed_tags_controller.rb`
- `app/presenters/tag_relationships_presenter.rb`
- `app/serializers/rest/tag_serializer.rb`

Tests may require new files because this Fedibird branch currently has little/no focused coverage for these exact surfaces.

Likely locations:

- `spec/controllers/api/v1/followed_tags_controller_spec.rb`
- `spec/presenters/tag_relationships_presenter_spec.rb`
- `spec/serializers/rest/tag_serializer_spec.rb`
- a focused tags API request/controller spec for follow/unfollow bridge behavior

Follow the repository's existing test organization rather than forcing these exact paths if a nearby established convention is better.

Durable project documentation should also be updated:

- `docs/hashtag-subsystem-upstream-unification.md`

Record that U3b-1 switches standard relation reads to `TagFollow` while writes/delivery remain legacy.

## Do not modify just to make specs green

Do not change unrelated behavior in:

- authentication status codes
- tag normalization
- tag display_name
- unrelated pagination utilities
- feed delivery
- Elasticsearch
- Settings UI
- destination API
- database migrations

If existing unrelated tests fail, report them separately with evidence rather than broadening the PR.

## Validation commands

At minimum run focused RSpec for every file added/changed for this task.

A likely command is:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/controllers/api/v1/followed_tags_controller_spec.rb \
  spec/presenters/tag_relationships_presenter_spec.rb \
  spec/serializers/rest/tag_serializer_spec.rb
```

Add any tags API spec you create to the command.

Also rerun U3a structural specs because U3b-1 depends on synchronous mirroring:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/models/follow_tag_spec.rb \
  spec/services/hashtag_unification/follow_tag_mirror_spec.rb \
  spec/services/hashtag_unification/follow_tag_backfill_spec.rb \
  spec/services/hashtag_unification/follow_tag_parity_spec.rb
```

Run RuboCop on every Ruby file modified by this PR.

## Cursor completion protocol

When implementation is complete:

1. run the focused U3b-1 specs
2. run the U3a mirror/backfill/parity regression specs
3. run RuboCop on modified Ruby files
4. update `docs/hashtag-subsystem-upstream-unification.md` with the durable U3b-1 state
5. delete **this handoff file**:
   `docs/development/u3b1-tag-follow-read-cutover-cursor-task.md`
6. update the PR body or add a PR comment containing:
   - final head SHA
   - implementation summary
   - exact RSpec commands and results
   - exact RuboCop command and result
   - any unrelated pre-existing failures, clearly separated

Do not merge the PR.

ChatGPT will review the final diff and reported test results before merge approval.

## Acceptance criteria

U3b-1 is complete when all of the following are true:

- `TagRelationshipsPresenter` reads `TagFollow`
- `REST::TagSerializer#following` reads `TagFollow`
- `GET /api/v1/followed_tags` reads and paginates `TagFollow`
- multi-destination follows appear once in followed-tags
- List-only follows still report `following: true`
- standard follow/unfollow still writes legacy `FollowTag` and succeeds through U3a mirror
- no fan-out/feed/destination-management read or write path is cut over
- no Tag identity behavior changes
- no database migration is added
- focused U3b-1 specs are green
- U3a mirror/backfill/parity regression specs are green
- no new RuboCop offenses are introduced
- handoff markdown is removed before final review
