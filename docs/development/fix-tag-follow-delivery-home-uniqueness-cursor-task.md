# Cursor task: fix TagFollowDelivery Home uniqueness validation

## Purpose

Fix the known model-level uniqueness bug in `TagFollowDelivery` before U3b-3 begins writing canonical destinations directly.

This is a deliberately small prerequisite PR.

Current production architecture after U3b-2:

- standard hashtag-follow relation reads use `TagFollow`
- FanOut and FeedManager destination reads use `TagFollowDelivery`
- ordinary writes still go through legacy `FollowTag` and U3a SQL mirroring
- U3b-3 will begin moving management/write paths toward canonical destinations

U3a/U2 SQL paths bypass Active Record validation, so this bug has not blocked the migration so far. It will matter as soon as application code creates Home deliveries through the model.

## Bug

Current validation:

```ruby
validates :tag_follow_id, uniqueness: true, if: -> { list_id.nil? }
```

This means:

> when creating a Home row, require this `tag_follow_id` to be unique across **all** TagFollowDelivery rows.

That is stricter than the database constraint and stricter than the intended model.

Example valid state:

```text
TagFollow(account, tag)
  List A
  Home
```

If List A exists first, Active Record can reject creation of Home because a row with the same `tag_follow_id` already exists.

The database correctly permits this through the partial unique index:

```text
UNIQUE(tag_follow_id) WHERE list_id IS NULL
```

The model validation must match that condition.

## Required fix

Change the Home validation to scope uniqueness to Home rows only.

Expected shape:

```ruby
validates :tag_follow_id,
          uniqueness: { conditions: -> { where(list_id: nil) } },
          if: -> { list_id.nil? }
```

Equivalent clear Rails syntax is acceptable.

Do not change the database index.

Do not change List uniqueness behavior unless a failing focused spec proves it is necessary.

## Required regression coverage

Extend `spec/models/tag_follow_delivery_spec.rb`.

At minimum prove:

### 1. List-only first, then Home

```ruby
described_class.create!(tag_follow: tag_follow, list: list_a)
home = described_class.create!(tag_follow: tag_follow)
```

Expected:

- Home persists
- exactly one Home delivery exists
- List A remains

This is the regression that the current validator gets wrong.

### 2. Home first, then List

Keep/prove the existing peer-destination behavior still works.

### 3. Duplicate Home still rejected

Two Home rows for one TagFollow remain invalid at model level.

### 4. Duplicate concrete List still rejected

Existing List uniqueness remains intact.

### 5. Multiple different Lists still allowed

Existing peer-destination semantics remain intact.

## Non-goals

Do not change:

- `TagFollow`
- U3a mirror
- U2 backfill/parity
- FanOut
- FeedManager
- standard API
- Fedibird `/api/v1/follow_tags`
- Settings
- schema/migrations
- Tag identity
- any write authority

This PR fixes model validation only.

## Validation

Run:

```bash
RAILS_ENV=test bundle exec rspec spec/models/tag_follow_delivery_spec.rb
```

Also rerun the focused U3b-2 destination specs because they depend on this model:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/services/fan_out_on_write_service_hashtag_follow_spec.rb \
  spec/lib/feed_manager_hashtag_follow_spec.rb \
  spec/models/tag_follow_delivery_spec.rb
```

And U3a mirror regression:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/models/follow_tag_spec.rb \
  spec/services/hashtag_unification/follow_tag_mirror_spec.rb
```

Run RuboCop on the modified Ruby files.

## Cursor completion protocol

When complete:

1. run the focused specs above
2. run RuboCop
3. delete this handoff file:
   `docs/development/fix-tag-follow-delivery-home-uniqueness-cursor-task.md`
4. add a PR comment containing:
   - final head SHA
   - exact code change
   - exact RSpec commands/results
   - exact RuboCop result

Do not merge.

ChatGPT will review before merge.

## Acceptance criteria

- List-only then Home succeeds through Active Record
- Home then List succeeds
- duplicate Home remains rejected
- duplicate same List remains rejected
- different Lists remain allowed
- database schema is unchanged
- no unrelated behavior changes
- focused specs green
- no new RuboCop offenses
- handoff markdown removed before final review
