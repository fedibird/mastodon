# Cursor task: U3b-2 hashtag delivery read cutover

## Purpose

Implement U3b-2 of the hashtag subsystem upstream-unification project.

Current production state:

- U3a is merged and production-validated.
  - legacy `FollowTag` remains authoritative for writes
  - ordinary Active Record `FollowTag` mutations synchronously mirror into
    `TagFollow` + `TagFollowDelivery`
  - production parity has been confirmed `ok: true`
- U3b-1 is merged.
  - standard hashtag-follow relation reads now use `TagFollow`
  - `TagRelationshipsPresenter`
  - `REST::TagSerializer#following`
  - `GET /api/v1/followed_tags`

U3b-2 moves **delivery/read admission** from legacy destination rows to
`TagFollowDelivery`.

This is the first stage where actual Home/List hashtag delivery decisions use
the canonical relation/delivery structure.

## Why U3b-2 is delivery cutover, not management cutover

The Fedibird-specific `/api/v1/follow_tags/:id` API and Settings UI expose
legacy `follow_tags.id` as the resource ID.

The backfilled `tag_follow_deliveries.id` values are not guaranteed to be the
same IDs.

Do not silently break those external/edit URLs merely to finish an internal
migration.

Therefore U3b-2 intentionally leaves destination management on legacy
`FollowTag`.

The compatibility/resource-ID problem will be handled separately in U3b-3.

## Core model

Canonical relation:

```text
TagFollow
  account_id
  tag_id
  UNIQUE(account_id, tag_id)
```

Fedibird delivery extension:

```text
TagFollowDelivery
  tag_follow_id
  list_id nullable   # NULL = Home, N = List N
  media_only
```

Critical invariant:

```text
TagFollow exists != Home delivery exists
```

Home and Lists are peer destinations.

A List-only follow therefore has:

```text
TagFollow(account, tag)
  TagFollowDelivery(list_id = list.id)
  no Home delivery
```

and must deliver only to that List, not Home.

## U3b-2 production scope

Cut these delivery/read paths from `FollowTag` to
`TagFollow` + `TagFollowDelivery`:

1. `FanOutOnWriteService#deliver_to_hashtag_followers_home`
2. `FanOutOnWriteService#deliver_to_hashtag_followers_list`
3. `FeedManager#build_crutches` -> `crutches[:following_tag_by]`

Do not broaden the production change beyond those paths unless a narrowly
required helper/scope is needed.

## Explicitly unchanged

Do not change:

- `Api::V1::TagsController` follow/unfollow writes
- `Api::V1::FollowTagsController`
- `REST::FollowTagSerializer`
- Settings hashtag-follow controller/views/forms
- `FollowTag` write callbacks / U3a mirror direction
- standard U3b-1 read surfaces
- Tag identity / HashtagNormalizer / display_name
- Elasticsearch
- KeywordSubscribe
- AccountSubscribe / DomainSubscribe behavior
- database schema
- `TagFollowDelivery` create/update validation unless strictly required for
  a test fixture; this cutover is read-only
- multi-destination standard unfollow semantics

No migration should be added.

## Required FanOutOnWriteService semantics

Current legacy behavior is conceptually:

```ruby
FollowTag.home
  .where(tag: status.tags_without_mute)
  .with_media(status.proper)
  .merge(visibility_scope(status, FollowTag))
  .pluck(:account_id)
```

and:

```ruby
FollowTag.list
  .where(tag: status.tags_without_mute)
  .with_media(status.proper)
  .merge(visibility_scope(status, FollowTag))
  .pluck(:list_id)
```

The new implementation must preserve the same semantics using canonical
relations.

Recommended query shape:

```text
TagFollowDelivery
  JOIN tag_follows
  WHERE destination = Home or List
  WHERE tag_follows.tag_id in status.tags_without_mute
  WHERE delivery.media_only is compatible with status.proper
  WHERE TagFollow relation passes the existing visibility_scope
```

Important:

- `account_id` lives on `TagFollow`, not `TagFollowDelivery`
- apply `visibility_scope(status, TagFollow)` to the relation side
- Home delivery result IDs are `tag_follows.account_id`
- List delivery result IDs are `tag_follow_deliveries.list_id`
- preserve `.uniq` behavior
- do not infer Home from relation existence
- do not deliver a List-only relation to Home
- do not deliver a Home-only relation to any List

Prefer readable ActiveRecord joins/merge over hand-written SQL unless the ORM
cannot express the required query cleanly.

## Required FeedManager semantics

Current legacy crutch:

```ruby
FollowTag.where(
  account_id: receiver_id,
  tag: statuses.flat_map(&:tags).uniq.compact,
  list_id: list_id
).pluck(:tag_id).index_with(true)
```

Replace this with a canonical destination query.

Required meaning:

```text
list_id == nil
  => only explicit Home TagFollowDelivery rows count

list_id == N
  => only TagFollowDelivery(list_id: N) rows count
```

The relation account must equal `receiver_id`.

The returned map remains:

```ruby
{ tag_id => true }
```

Do not treat a bare `TagFollow` with zero deliveries as followed for feed
admission.

Do not treat a List delivery as a Home delivery or vice versa.

## Read-source sentinel requirement

This PR must prove the delivery paths actually read the canonical destination
structure.

### Positive sentinel

Create target-only canonical rows directly:

```text
TagFollow exists
TagFollowDelivery exists
FollowTag absent
```

Expected:

- FanOut delivers according to that canonical destination
- FeedManager hashtag crutch/admission sees that destination

This is intentionally inconsistent with U3a parity and exists only as a test
sentinel.

### Negative sentinel

Create a callback-bypassing legacy row:

```text
FollowTag exists
TagFollow absent
TagFollowDelivery absent
```

Use `insert_all!` or equivalent callback-bypass fixture.

Expected:

- FanOut does not deliver because U3b-2 no longer reads `FollowTag`
- FeedManager does not consider the tag followed

This must not be "repaired" in the fixture by running the mirror.

The purpose is to prove source authority.

## Required Home/List matrix

Add focused coverage for at least these cases.

### Home-only

```text
TagFollow
  delivery Home
```

Expected:

- hashtag status delivered to Home
- not delivered to an unrelated List

### List-only

```text
TagFollow
  delivery List A
```

Expected:

- not delivered to Home because no Home delivery exists
- delivered to List A
- not delivered to List B

This is a critical Fedibird invariant.

### Home + List

```text
TagFollow
  Home
  List A
```

Expected:

- delivered to Home
- delivered to List A
- no accidental duplicate delivery target IDs from query joins

### Multiple Lists

```text
TagFollow
  List A
  List B
```

Expected:

- both lists receive the status
- Home does not receive it unless a Home delivery exists

## media_only preservation

Destination-level `media_only` must remain authoritative.

Cover at least:

1. Home media_only=true + text-only status -> no Home delivery
2. Home media_only=true + media status -> Home delivery
3. List media_only=true + text-only status -> no List delivery
4. List media_only=true + media status -> List delivery

If the existing factory setup makes all four expensive, use a compact shared
example/matrix, but cover both Home and List.

Use `status.proper` exactly as the existing code does.

## visibility_scope preservation

The old FanOut query uses:

```ruby
merge(visibility_scope(status, FollowTag))
```

Do not lose this restriction while joining through `TagFollowDelivery`.

The new query should apply the same existing visibility logic to
`TagFollow`, which has `account_id`.

Add at least one focused regression that would catch accidentally ignoring the
visibility scope. Prefer the smallest stable case already used by surrounding
FanOut specs.

Do not redesign `visibility_scope` itself.

## tags_without_mute preservation

FanOut must continue using:

```ruby
status.tags_without_mute
```

Do not accidentally switch to all `status.tags`.

TagAccountMute behavior is not part of this migration.

## FeedManager reply-admission coverage

`crutches[:following_tag_by]` matters when deciding whether replies are
admitted into Home/List feeds.

Add focused tests proving destination-specific hashtag follows still override
reply filtering correctly.

Suggested Home case:

```text
receiver follows posting account
status is a reply that would otherwise be filtered
status has tag X
receiver has canonical Home delivery for tag X
=> reply is not filtered from Home
```

Suggested List case:

```text
list owner/list setup
reply would otherwise be filtered from that List
status has tag X
owner has canonical delivery for tag X specifically to that List
=> reply is not filtered from that List
```

Also prove the wrong destination does not unlock the reply:

- List-only X must not make Home admission true
- Home-only X must not make List A admission true
- List B must not make List A admission true

Use the public `FeedManager#filter?` behavior where practical rather than
testing only the private hash builder.

## U3a bridge regression

Keep proving normal management writes still feed the new delivery path.

At least one integration-style case should:

1. create `FollowTag` through normal Active Record
2. let U3a mirror it
3. assert canonical relation/delivery exists
4. exercise U3b-2 delivery behavior
5. verify the expected Home/List target receives or admits the status

This guards the boundary between the still-legacy write path and new delivery
read path.

## Rollback property

There is no schema/data migration in U3b-2.

Rollback must remain:

```text
deploy problem
  -> revert application code to U3b-1
  -> FanOut/FeedManager read legacy FollowTag again
  -> legacy writes were never stopped
```

Do not delete or stop writing `follow_tags`.

## Likely production files

Expected:

- `app/services/fan_out_on_write_service.rb`
- `app/lib/feed_manager.rb`

A small reusable scope/helper on `TagFollowDelivery` or `TagFollow` is
acceptable if it makes both call sites clearer and is directly covered.

Avoid introducing an abstraction used nowhere else.

## Likely specs

Expected to extend:

- `spec/services/fan_out_on_write_service_spec.rb`
- `spec/lib/feed_manager_spec.rb`

A new focused spec file is acceptable if the existing files are too broad, for
example:

- `spec/services/fan_out_on_write_service_hashtag_follow_spec.rb`
- `spec/lib/feed_manager_hashtag_follow_spec.rb`

Prefer isolated focused coverage if it avoids unrelated flaky legacy examples.

Also rerun:

- U3a mirror/backfill/parity specs
- U3b-1 standard read specs

## Durable documentation

Update:

`docs/hashtag-subsystem-upstream-unification.md`

Record:

- U3b-2 makes hashtag delivery/fan-out and FeedManager tag admission read
  `TagFollowDelivery`
- legacy `FollowTag` remains write authority and management/resource-ID
  compatibility surface
- `/api/v1/follow_tags` / Settings are explicitly deferred to U3b-3 because
  their IDs are legacy `follow_tags.id`
- rollback remains application-code-only while dual-write is retained

## Production deployment gate

Document that administrators must run immediately before U3b-2 deploy:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

Required:

```json
"ok": true
```

After deploy, exercise real mutations and rerun parity.

Recommended canary matrix:

- Home-only follow receives tagged post only in Home
- List-only follow receives it only in that List
- Home + List receives both
- media_only blocks text-only and admits media
- removing Home while retaining List stops Home delivery but keeps List
- removing final destination stops delivery

Then rerun parity and require `ok: true`.

## Validation commands

Run the focused U3b-2 specs you add/modify.

Then rerun U3a:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/models/follow_tag_spec.rb \
  spec/services/hashtag_unification/follow_tag_mirror_spec.rb \
  spec/services/hashtag_unification/follow_tag_backfill_spec.rb \
  spec/services/hashtag_unification/follow_tag_parity_spec.rb
```

Rerun U3b-1:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/controllers/api/v1/followed_tags_controller_spec.rb \
  spec/presenters/tag_relationships_presenter_spec.rb \
  spec/serializers/rest/tag_serializer_spec.rb \
  spec/controllers/api/v1/tags_controller_spec.rb
```

Run RuboCop on every Ruby file modified by this PR.

If broad pre-existing spec files contain unrelated failures, report the exact
failing examples separately and show the new focused examples are green. Do not
change unrelated behavior merely to make an old broad suite green.

## Cursor completion protocol

When implementation is complete:

1. run focused U3b-2 specs
2. run U3a regression specs
3. run U3b-1 regression specs
4. run RuboCop on all modified Ruby files
5. update the durable unification document
6. delete this handoff file:
   `docs/development/u3b2-tag-follow-delivery-read-cutover-cursor-task.md`
7. add a PR comment with:
   - final head SHA
   - production files changed
   - exact semantic summary
   - exact RSpec commands/results
   - exact RuboCop command/result
   - any unrelated failures clearly identified

Do not merge.

ChatGPT will review final code and validation before merge authorization.

## Acceptance criteria

U3b-2 is ready when:

- FanOut hashtag Home delivery reads explicit Home `TagFollowDelivery`
- FanOut hashtag List delivery reads explicit List `TagFollowDelivery`
- FeedManager `following_tag_by` reads destination-specific
  `TagFollowDelivery`
- bare `TagFollow` does not imply Home
- List-only never leaks to Home
- Home-only never leaks to List
- multiple Lists remain distinct
- destination `media_only` semantics are preserved
- existing visibility and tag-mute semantics are preserved
- canonical-only positive sentinels work
- legacy-only callback-bypass negative sentinels prove old table is not read
- normal legacy writes still reach the new delivery path through U3a mirror
- U3a and U3b-1 regressions remain green
- no management/API resource-ID behavior changes
- no schema migration
- no new RuboCop offenses
- handoff markdown is removed before final review
