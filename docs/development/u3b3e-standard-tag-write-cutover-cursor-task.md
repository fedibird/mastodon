# U3b-3e Cursor task: cut standard hashtag follow/unfollow writes over to canonical relations

## Goal

Finish the remaining normal legacy write path in Phase A of hashtag subsystem upstream unification.

After PR #133, standard `Api::V1::TagsController#follow/#unfollow` is the only intended normal runtime path that still writes `FollowTag` Active Record rows and depends on U3a callbacks.

This PR must move that standard Mastodon API surface to canonical:

- `TagFollow` = upstream-compatible account/tag relation
- `TagFollowDelivery` = Fedibird explicit Home/List delivery extension
- `follow_tags` = callback-free rollback shadow and compatibility-ID allocator only

Do not remove `FollowTag`, U3a, or the `follow_tags` table in this PR. They remain for rollback and soak.

## Base

Base this work on the merged #133 state:

`9fa862673b8db76f0695b57fbf57c23302530fdb`

## Current controller

Current standard writes are still:

```ruby
def follow
  FollowTag.create!(tag: @tag, account: current_account, rate_limit: true)
  render json: @tag, serializer: REST::TagSerializer
end

def unfollow
  FollowTag.find_by(account: current_account, tag: @tag)&.destroy!
  render json: @tag, serializer: REST::TagSerializer
end
```

Those direct legacy writes must disappear.

## Architectural contract

The standard Mastodon API operates on the **follow relation**, not on one Fedibird destination row.

Fedibird destination management remains available through:

- `/api/v1/follow_tags`
- Settings follow-tag management

Those surfaces remain row/destination-oriented.

The standard API contract after this PR is:

```text
POST /api/v1/tags/:id/follow
  = ensure canonical TagFollow exists
  + ensure explicit Home TagFollowDelivery exists
  + preserve all existing List destinations

POST /api/v1/tags/:id/unfollow
  = remove the canonical TagFollow relation
  + remove ALL Home/List TagFollowDelivery rows beneath it
  + remove ALL matching rollback-shadow follow_tags rows
```

A `TagFollow` existing by itself must never imply Home delivery.

## Required implementation shape

Prefer extending `HashtagUnification::TagFollowDeliveryWriter` with relation-level public operations so all compatibility-ID allocation and rollback-shadow mutation remains centralized.

Suggested public API:

```ruby
standard_follow!(account:, tag:, rate_limit: false)
standard_unfollow!(account:, tag:)
```

Exact method names may differ if a clearer small service boundary emerges, but do not duplicate the raw shadow-allocation/synchronization logic in the controller.

The controller should become thin and must not call `FollowTag.create!/save/update/destroy`.

## Standard follow semantics

### Fresh relation

Given no existing relation/destination:

```text
before:
  no TagFollow
  no TagFollowDelivery
  no follow_tags shadow

after standard follow:
  TagFollow(account, tag)
    -> Home delivery

  matching follow_tags Home rollback shadow
```

The Home delivery must receive a compatibility ID allocated from the existing `follow_tags` sequence, exactly as the canonical destination writer does today.

The response must report `following: true`.

### Lists-only relation

This is a major real Fedibird state and must remain supported.

```text
before:
  TagFollow(#ruby)
    -> List A
    -> List B

standard follow

after:
  TagFollow(#ruby)
    -> Home
    -> List A
    -> List B
```

Requirements:

- create exactly one explicit Home delivery
- preserve every List delivery
- preserve each List destination's `media_only`
- allocate a new rollback-shadow ID only for the new Home destination
- do not synthesize or rewrite List destinations
- response remains `following: true`

### Existing Home

Standard follow must be idempotent, matching upstream Mastodon relation semantics.

If Home already exists:

- return HTTP 200
- do not create another Home delivery
- do not create another shadow row
- preserve all peers
- do not change `media_only`

This intentionally improves over the current legacy duplicate-row/422 behavior and converges on upstream's `find_or_create_by!` behavior.

### Rate limiting

Do not lose standard follow rate-limit behavior.

The canonical `TagFollow` model already includes `RateLimitable`.

For creation of a **new canonical TagFollow relation**, preserve upstream-style creation with `rate_limit: true` (equivalent in intent to upstream `TagFollow.create_with(rate_limit: true).find_or_create_by!`).

If the canonical relation already exists (for example a Lists-only relation), adding the missing Home destination must not create a second `TagFollow`; therefore no second TagFollow `after_create` rate-limit event is expected. This is the desired canonical relation-based rate-limit semantics.

Keep the controller's existing:

```ruby
override_rate_limit_headers :follow, family: :follows
```

### New Tag object

`set_or_create_tag` can produce an unsaved `Tag.new`.

The canonical follow operation must ensure that a newly introduced valid hashtag is persisted and that the object rendered by the controller represents the persisted canonical Tag so the response correctly reports `following: true`.

Pin this in a controller spec.

## Standard unfollow semantics

This PR deliberately chooses the upstream-compatible relation contract.

### Home only

```text
TagFollow
  -> Home

standard unfollow

=> no TagFollow
=> no deliveries
=> no matching follow_tags shadow
=> response following: false
```

### Lists only

```text
TagFollow
  -> List A
  -> List B

standard unfollow

=> remove the relation and BOTH List destinations
=> remove their rollback shadows
=> response following: false
```

This is intentional.

A client that wants to remove only one Fedibird destination must use the destination-management API/Settings surface, not the standard Mastodon `/tags/:id/unfollow` endpoint.

### Home + Lists

Remove Home and every List destination together.

Do not leave a Lists-only relation after standard unfollow.

### Already unfollowed

If neither canonical relation nor rollback-shadow rows exist, standard unfollow is idempotent:

- HTTP 200
- response `following: false`

## Relation-level rollback-shadow verification

Because standard unfollow is destructive across every destination, it must fail closed unless the complete canonical relation is rollback-safe.

Before destructive mutation, verify the complete relation between:

```text
TagFollow + TagFollowDelivery
vs
follow_tags rollback shadow
```

For the selected `(account_id, tag_id)`, require exact destination correspondence.

At minimum verify:

- every canonical delivery has non-null `legacy_follow_tag_id`
- every compatibility ID resolves to exactly one shadow row
- shadow account_id matches
- shadow tag_id matches
- shadow list_id matches
- shadow media_only matches
- there are no extra legacy `follow_tags` rows for that account/tag that are absent canonically
- there are no missing legacy rows
- a canonical `TagFollow` with zero deliveries is inconsistent and must fail closed
- legacy-only rows with no canonical relation are inconsistent and must fail closed

Use `HashtagUnification::TagFollowDeliveryWriter::InconsistentLegacyShadowError` or a clearly equivalent validation error so the API returns 422 through the existing API error handling.

Do not silently repair or delete inconsistent data in the standard endpoint.

For standard follow on an already-existing relation, verify rollback-shadow consistency before mutating it. A broken relation should fail closed instead of layering a new Home destination on top of inconsistent rollback state.

For a truly fresh relation, no canonical relation and no legacy shadow rows is valid.

## Atomicity and lock boundary

Standard relation follow/unfollow must be atomic.

For relation-level destructive work, keep lock ordering compatible with the current transitional writer as closely as practical:

```text
follow_tags rollback-shadow rows
  -> TagFollowDelivery rows
  -> parent TagFollow
```

Do not implement standard unfollow as independent committed per-destination deletes.

All canonical deletions and all rollback-shadow deletions must commit or roll back together.

Shadow deletion must remain callback-free (`delete_all`/SQL), so U3a does not recurse.

## U3a independence

Focused tests must prove the standard canonical writes no longer depend on `HashtagUnification::FollowTagMirror`.

Stub the mirror to raise during:

- fresh standard follow
- Lists-only -> add Home
- standard unfollow with multiple destinations

Those operations must still succeed.

After this PR, U3a should remain in the codebase for rollback only; it should no longer be required by any intended normal hashtag-follow writer.

Do not remove it yet.

## Existing destination writer behavior

Do not regress the already-merged per-destination operations:

- compatibility API create/update/destroy
- Settings create/update/destroy
- Home/List moves
- tag rename
- `media_only`
- peer preservation
- compatibility IDs
- missing-shadow fail-closed behavior

Refactoring shared private methods inside `TagFollowDeliveryWriter` is allowed if these contracts remain unchanged.

## Controller requirements

Update `Api::V1::TagsController` so:

- `follow` performs the canonical standard follow operation
- `unfollow` performs the canonical relation-level unfollow operation
- no `FollowTag.create!`
- no `FollowTag.find_by(...).destroy!`
- serializer response remains `REST::TagSerializer`
- standard auth/scopes remain unchanged
- rate-limit headers remain unchanged
- no destination parameter is added

Do not alter `show` behavior except where strictly required for this cutover.

## Required controller/service regression matrix

Add focused coverage for at least all of the following.

### Follow

1. fresh standard follow creates one TagFollow + explicit Home delivery + exact shadow
2. fresh follow works with `FollowTagMirror` disabled
3. response reports `following: true`
4. following a brand-new valid tag persists/render the correct Tag
5. repeated standard follow is HTTP 200 and creates no duplicate rows
6. Lists-only + one List -> adds Home and preserves List
7. Lists-only + multiple Lists -> adds Home and preserves all Lists
8. different List `media_only` values remain unchanged
9. Home + List -> idempotent; peers unchanged
10. compatibility ID/shadow for the newly added Home is valid
11. fresh relation creation retains canonical TagFollow rate-limit behavior
12. inconsistent existing relation/shadow fails closed and does not add Home

### Unfollow

13. Home-only -> removes relation, delivery, shadow
14. one-List-only -> removes relation and List destination/shadow
15. multiple-Lists-only -> removes all
16. Home + multiple Lists -> removes all
17. `media_only` differences do not affect complete removal
18. response reports `following: false`
19. already-unfollowed -> HTTP 200, no mutation
20. multiple-destination unfollow works with `FollowTagMirror` disabled
21. missing shadow -> 422, nothing deleted
22. wrong shadow account/tag/list -> 422, nothing deleted
23. wrong shadow `media_only` -> 422, nothing deleted
24. extra legacy-only destination -> 422, nothing deleted
25. canonical zero-delivery relation -> 422, relation retained
26. legacy-only relation -> 422, shadow retained

### Cross-surface interoperability

27. destination created through `/api/v1/follow_tags` can participate in standard follow/unfollow
28. destination created through Settings writer can participate
29. standard follow Home appears through canonical management GET with its compatibility ID
30. after standard unfollow, management GET has no destinations for the relation
31. parity is `ok: true` and `management_ready: true` after every successful mutation scenario

## Existing regression suite

Re-run the full U3 hashtag-follow regression set, including at minimum:

- `spec/controllers/api/v1/tags_controller_spec.rb`
- `spec/controllers/api/v1/follow_tags_controller_spec.rb`
- `spec/controllers/settings/follow_tags_controller_spec.rb`
- `spec/services/hashtag_unification/tag_follow_delivery_writer_spec.rb`
- `spec/services/hashtag_unification/follow_tag_mirror_spec.rb`
- `spec/services/hashtag_unification/follow_tag_backfill_spec.rb`
- `spec/services/hashtag_unification/follow_tag_parity_spec.rb`
- `spec/models/follow_tag_spec.rb`
- `spec/models/tag_follow_spec.rb`
- `spec/models/tag_follow_delivery_spec.rb`
- `spec/controllers/api/v1/followed_tags_controller_spec.rb`
- `spec/presenters/tag_relationships_presenter_spec.rb`
- `spec/serializers/rest/tag_serializer_spec.rb`
- `spec/serializers/rest/follow_tag_serializer_spec.rb`
- `spec/services/fan_out_on_write_service_hashtag_follow_spec.rb`
- `spec/lib/feed_manager_hashtag_follow_spec.rb`

## Deliberate behavior change

Document this clearly:

Before U3b-3e, Fedibird's legacy standard unfollow used:

```ruby
FollowTag.find_by(account: current_account, tag: @tag)&.destroy!
```

With multiple destination rows, that could remove only one arbitrary destination and leave the account still following the tag.

After U3b-3e, the standard Mastodon endpoint always removes the complete canonical follow relation and all destinations.

This is the intended upstream-compatible API contract.

The repository contains a separate Fedibird destination-management API specifically for per-destination removal.

## Upstream reference

Mastodon v4.2.13 standard controller uses canonical `TagFollow` and idempotent follow:

```ruby
TagFollow.create_with(rate_limit: true).find_or_create_by!(tag: @tag, account: current_account)
TagFollow.find_by(account: current_account, tag: @tag)&.destroy!
```

Fedibird must preserve that relation-level meaning while explicitly creating/removing `TagFollowDelivery` extension rows and rollback shadows.

Do not blindly copy unrelated upstream behavior.

In particular, do **not** add `TagUnmergeWorker` or unrelated feed-history behavior in this PR. Fedibird does not currently have that worker/path; the runtime delivery cutover is already handled separately by U3b-2.

## Explicitly out of scope

Do not change:

- tag identity / `HashtagNormalizer`
- `display_name` semantics
- FanOut hashtag delivery
- FeedManager hashtag admission
- management resource routes or JSON shape
- Settings forms
- standard auth scopes
- schema
- `FollowTag` model removal
- U3a removal
- `follow_tags` table removal
- model association cleanup outside what is strictly required
- TagUnmergeWorker / historical home-feed cleanup behavior
- Phase B tag canonicalization

## Durable documentation

Update `docs/hashtag-subsystem-upstream-unification.md` with a new U3b-3e section recording:

- standard follow ensures explicit Home
- standard follow is idempotent
- Lists-only + standard follow adds Home without deleting Lists
- standard unfollow removes the complete relation and every destination
- exact relation-level rollback-shadow verification
- canonical TagFollow rate-limit semantics
- U3a is now rollback-only, not an intended normal writer dependency
- the remaining work is soak + legacy association/runtime cleanup before U4

Remove this temporary handoff document before implementation is considered complete.

## Deployment / rollback gate

Before production deployment:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

Require:

```text
ok: true
management_ready: true
```

After deploy, canary at least:

1. fresh standard follow -> Home
2. Lists-only standard follow -> Home + Lists preserved
3. temporary Home + List relation -> standard unfollow -> all removed
4. inspect the same resources through `/api/v1/follow_tags`
5. rerun parity and require both gates true

Rollback remains application-code-only: revert to #133 behavior while the exact `follow_tags` shadow still exists. That is why this PR must keep shadow parity exact and must not remove U3a or the legacy table.

## Completion report

When done, leave a PR comment with:

- final HEAD SHA
- files changed
- chosen service/writer shape
- exact standard follow/unfollow semantics
- how rate limiting is preserved
- how relation-level shadow consistency is checked
- focused test results
- full U3 regression result
- RuboCop result

Do not merge. ChatGPT will review the completed implementation and validation.
