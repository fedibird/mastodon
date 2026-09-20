# Cursor task: U3b-3a legacy resource-ID foundation

## Purpose

Implement U3b-3a of the hashtag subsystem upstream-unification project.

This is a compatibility-ID foundation PR. It does not yet cut the Fedibird destination-management API or Settings UI over to the canonical models.

Current architecture after U3b-2 and PR #129:

- standard hashtag-follow relation reads use TagFollow
- FanOut hashtag delivery and FeedManager tag admission use TagFollowDelivery
- ordinary writes and Fedibird destination management still use legacy FollowTag
- U3a mirrors legacy writes into the canonical tables
- TagFollowDelivery Home uniqueness now matches the DB partial index

The remaining blocker for management cutover is stable resource identity.

Fedibird currently exposes follow_tags.id in:

- /api/v1/follow_tags/:id
- REST::FollowTagSerializer#id
- Settings edit/delete routes such as /settings/follow_tags/:id/edit

Existing clients/bookmarks may retain those IDs. Backfilled tag_follow_deliveries.id values are not guaranteed to equal the legacy follow_tags.id values.

Do not silently replace those IDs.

## Design decision

Add a compatibility identifier to the canonical destination row:

    tag_follow_deliveries.legacy_follow_tag_id

Semantics:

    TagFollowDelivery.id
      = canonical internal primary key

    TagFollowDelivery.legacy_follow_tag_id
      = stable compatibility resource ID historically exposed as follow_tags.id

The column name is intentionally historical. It represents the old external resource identity.

Do not rewrite TagFollowDelivery primary keys to match legacy IDs.

Do not add a foreign key from legacy_follow_tag_id to follow_tags.

The lack of FK is intentional because the value must survive after the legacy follow_tags table is eventually removed; it is a compatibility identity, not a continuing relational dependency.

## Migration requirements

Add a bigint column legacy_follow_tag_id to tag_follow_deliveries.

Requirements:

- null: true
- no default
- unique index
- no foreign key
- update db/schema.rb

The column must remain nullable in this PR because schema migration happens before compatibility-ID backfill and inconsistent/target-only rows must remain diagnosable.

Prefer repository-safe migration style. Use a concurrent unique index if consistent with current migration conventions.

Do not add a sequence in this PR.

## Deterministic mapping rule

For one canonical destination identified by:

    account_id, tag_id, list_id

the compatibility ID is the matching legacy follow_tags.id.

Normal source data has one legacy row per destination.

If pathological duplicate legacy destination rows exist, use:

    MIN(follow_tags.id)

as the deterministic compatibility ID.

This is only a deterministic backfill/mirror rule. A source with duplicate destination rows is not management-cutover-ready because multiple historically exposed IDs collapse to one canonical destination.

Do not attempt to preserve multiple external IDs on one canonical row.

## FollowTagBackfill changes

Extend U2 backfill so every upserted delivery also gets legacy_follow_tag_id.

For Home, aggregate:

    MIN(source.id) AS legacy_follow_tag_id

For each concrete List group, also use:

    MIN(source.id) AS legacy_follow_tag_id

On conflict, update legacy_follow_tag_id along with media_only and timestamps.

Backfill must remain idempotent, restartable, source-preserving, false-wins for media_only, and compatible with existing PRUNE behavior.

## FollowTagMirror changes

U3a mirror must maintain the compatibility ID for ordinary legacy writes.

For Home and each concrete List destination:

    legacy_follow_tag_id = MIN(matching follow_tags.id)

and update it on conflict.

This must handle normal create, media_only update, destination movement, tag/account movement already covered by existing callbacks, and stale destination cleanup.

Important example:

    FollowTag id = 123
    initially List A
    update list_id -> NULL

Expected canonical state:

    old List A delivery removed
    Home delivery exists
    Home.legacy_follow_tag_id == 123

The compatibility identity follows the legacy resource row.

Do not introduce reverse mirroring or callback loops. Legacy remains write source in U3b-3a.

## TagFollowDelivery model

Prefer adding model validation matching the unique index:

    validates :legacy_follow_tag_id, uniqueness: true, allow_nil: true

if consistent with project conventions.

Do not make it required/non-null yet.

Do not alter Home/List destination validations.

## FollowTagParity changes

Extend parity so compatibility identity is verifiable before management cutover.

In the source expected-destination CTE derive:

    MIN(id) AS legacy_follow_tag_id

for each account_id, tag_id, list_id group.

Include tag_follow_deliveries.legacy_follow_tag_id in target comparison.

Required metrics must detect at least:

1. source-backed canonical destinations with missing compatibility ID
2. compatibility-ID mismatch against expected MIN(follow_tags.id)
3. duplicate legacy destination groups that prevent lossless management-ID cutover

Suggested fields:

    target.deliveries_without_legacy_follow_tag_id
    differences.legacy_follow_tag_id_mismatches

The existing source.duplicate_destination_groups metric already identifies ID ambiguity.

### ok vs management_ready

Keep semantic parity and management-cutover readiness conceptually distinct.

Recommended output:

    {
      "ok": true,
      "management_ready": true
    }

After U3b-3a, compatibility-ID parity is part of ok. A source-backed canonical delivery with nil or wrong legacy_follow_tag_id means backfill is incomplete and ok must be false.

management_ready must require:

- ok == true
- source.duplicate_destination_groups == 0
- any other compatibility-identity hard blockers you identify

This preserves support for collapsing pathological source duplicates while explicitly preventing U3b-3b management cutover when old IDs cannot be represented losslessly.

## Operational sequence

U3b-3a must support:

    old app / existing data
      -> add nullable legacy_follow_tag_id + unique index
      -> deploy updated mirror/backfill/parity
      -> RAILS_ENV=production APPLY=1 bundle exec rake hashtag_unification:follow_tag_backfill
      -> RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
      -> require ok: true and management_ready: true

No management controller cutover occurs in this PR.

## Required regression coverage

### A. Backfill preserves exact legacy IDs

For normal Home and List source rows:

    FollowTag.id == N
    => matching TagFollowDelivery.legacy_follow_tag_id == N

Cover both Home and List.

### B. Backfill is idempotent

Run APPLY twice. Compatibility IDs remain the same.

### C. Duplicate source destination chooses MIN(id)

Create duplicate legacy rows through callback-bypassing insertion.

After backfill:

    delivery.legacy_follow_tag_id == MIN(source ids)

Existing false-wins media_only behavior must remain.

### D. Duplicate source blocks management readiness

With duplicate source destination rows, backfill may still construct the canonical destination, but management_ready must be false.

### E. Mirror populates compatibility ID

Normal FollowTag create must produce a canonical delivery whose legacy_follow_tag_id equals FollowTag.id.

Cover Home and List if practical.

### F. Mirror keeps ID through destination movement

Example:

    FollowTag id 123 -> List A
    update same FollowTag row -> Home

Expected:

    canonical List A removed
    canonical Home exists
    Home.legacy_follow_tag_id == 123

### G. Parity detects missing ID

After successful backfill, clear one delivery legacy_follow_tag_id.

Expected:

    ok == false
    missing/mismatch compatibility metric > 0

### H. Parity detects wrong ID

After successful backfill, assign a non-matching unused ID.

Expected:

    ok == false
    legacy_follow_tag_id_mismatches > 0

### I. Unique compatibility ID

If model validation is added, cover duplicate non-null legacy_follow_tag_id.

The database unique index remains final concurrency protection.

## Important source-data edge case

Do not assume every Fedibird installation has zero duplicate legacy destinations merely because fedibird.com currently does.

The analyzer/backfill intentionally supports duplicate destinations.

For U3b-3a:

- collapse duplicates deterministically as before
- choose MIN(id) as compatibility ID
- report management cutover as unsafe

Do not fail basic backfill merely because duplicates exist unless existing safety rules already require that condition.

## Explicitly out of scope

Do not modify:

- Api::V1::FollowTagsController
- REST::FollowTagSerializer
- Settings follow-tag controller/views
- Api::V1::TagsController
- FanOut
- FeedManager
- standard U3b-1 read surfaces
- Tag identity
- direct canonical write authority
- old table removal

No API or UI behavior changes in U3b-3a.

## Durable documentation

Update docs/hashtag-subsystem-upstream-unification.md.

Document:

- U3b-3a adds canonical compatibility resource identity
- legacy_follow_tag_id is intentionally not an FK
- existing external resource IDs are preserved rather than replaced by TagFollowDelivery.id
- U2/U3a keep compatibility IDs synchronized from the legacy source
- duplicate legacy destination groups block management cutover
- U3b-3b may proceed only when parity reports both semantic parity and management readiness
- column remains nullable until later cleanup/cutover proves a stronger constraint is safe

## Validation commands

Run:

    RAILS_ENV=test bundle exec rspec       spec/models/tag_follow_delivery_spec.rb       spec/services/hashtag_unification/follow_tag_backfill_spec.rb       spec/services/hashtag_unification/follow_tag_mirror_spec.rb       spec/services/hashtag_unification/follow_tag_parity_spec.rb

Rerun U3b-2:

    RAILS_ENV=test bundle exec rspec       spec/services/fan_out_on_write_service_hashtag_follow_spec.rb       spec/lib/feed_manager_hashtag_follow_spec.rb

Rerun U3b-1:

    RAILS_ENV=test bundle exec rspec       spec/controllers/api/v1/followed_tags_controller_spec.rb       spec/presenters/tag_relationships_presenter_spec.rb       spec/serializers/rest/tag_serializer_spec.rb       spec/controllers/api/v1/tags_controller_spec.rb

Run RuboCop on every modified Ruby file.

## Cursor completion protocol

When complete:

1. run focused U3b-3a specs
2. rerun U3b-2 specs
3. rerun U3b-1 specs
4. run RuboCop
5. update durable architecture documentation
6. delete docs/development/u3b3a-legacy-resource-id-foundation-cursor-task.md
7. add a PR comment with final head SHA, migration filename, schema change, mapping rule, parity output contract, exact RSpec results, exact RuboCop result, and unrelated failures separately identified

Do not merge.

ChatGPT will review before merge.

## Acceptance criteria

U3b-3a is ready when:

- canonical deliveries have nullable unique legacy_follow_tag_id
- no FK ties it to the old table
- U2 backfill populates exact legacy IDs
- U3a mirror maintains compatibility IDs
- duplicate source destinations deterministically choose MIN(id)
- duplicate source destinations explicitly block management readiness
- parity detects missing/wrong compatibility IDs
- normal source data reports ok: true and management_ready: true
- existing API/Settings behavior remains untouched
- no delivery/read behavior changes
- no Tag identity changes
- focused U3b-3a specs are green
- U3b-2 and U3b-1 regressions remain green
- no new RuboCop offenses
- handoff markdown is removed before final review
