# Hashtag subsystem upstream unification

Status: **implementation in progress**. U0/U0.1 analyzers, U1 schema expansion, U2 backfill/parity tooling, U3a dual-write, U3b-1 standard read cutover, and U3b-2 hashtag delivery/read-admission cutover have been merged or are in review. Writes and destination management still use legacy `FollowTag`. Standard following-state reads use `TagFollow`. Home/List delivery and FeedManager tag admission use `TagFollowDelivery`.

Base for this design: Fedibird PR #117 head
`777ca4eabe36f6dc0abb8ec431505ecbc18d6fa8` (2026-09-19).

Primary upstream references:

- Mastodon #18795 — hashtag normalization and `tags.display_name`
- Mastodon #26872 — Admin Tags API
- Mastodon v4.2 `Tag`, `TagFollow`, tag serializers, tag API, and featured-tag code

The goal is not to make Fedibird behave like upstream in every product detail.
The goal is to make upstream Mastodon the canonical implementation for concepts
that mean the same thing, while preserving Fedibird product semantics as small,
explicit extensions.

---

## 1. Why this work exists

Fedibird implemented hashtag following before upstream Mastodon. When upstream
later implemented a substantially similar feature, it used a different model
and schema:

- Fedibird: `FollowTag` / `follow_tags`
- Mastodon: `TagFollow` / `tag_follows`

Fedibird retained its implementation because it already had additional routing
semantics, most importantly per-destination Home/List delivery and
`media_only`.

A second divergence later appeared around hashtag identity. Upstream introduced
`HashtagNormalizer`, canonical `Tag#name`, and `display_name`; Fedibird kept
its historical identity rules to avoid forcing a risky merge of existing data
and behavior.

The result is a historical cross-wiring of two independently evolved designs.

This project removes that accidental divergence.

---

## 2. Top-level architectural rule

> **Canonical data model and hashtag identity come from upstream Mastodon.
> Intentional Fedibird feed-routing semantics remain Fedibird extensions.**

Use this test for every difference encountered during implementation:

1. If Fedibird and upstream mean the same thing, use the upstream model and
   source structure.
2. If the difference is only historical naming or implementation shape, remove
   the Fedibird duplicate.
3. If the difference is intentional Fedibird product behavior, keep it, but
   isolate it behind the smallest possible extension boundary.
4. Do not preserve accidental divergence merely because it exists today.
5. Do not erase intentional Fedibird semantics merely because upstream behaves
   differently.

The desired long-term shape is:

```text
Mastodon upstream implementation
            +
small, explicit Fedibird extensions
```

This project should become a reference pattern for later Fedibird/upstream
unification work.

---

## 3. Non-negotiable Fedibird timeline semantics

### 3.1 Home and List are peer destinations

Fedibird does **not** treat Home as the mandatory primary destination and Lists
as subordinate filters.

Conceptually, Home is close to an ID-less primary list:

```text
Timeline destinations
  - Home
  - List A
  - List B
  - List C
```

Subscriptions may target any one or more of them.

This is already visible across Fedibird subscription features:

- `FollowTag`
- `AccountSubscribe`
- `DomainSubscribe`
- `KeywordSubscribe`

They consistently use:

```text
list_id = NULL  => Home
list_id = N     => List N
```

Therefore this is not a hashtag-only exception. It is part of Fedibird's
subscription architecture.

### 3.2 Following a hashtag does not imply Home delivery

These are all valid and common Fedibird states:

```text
#ruby -> Home
```

```text
#ruby -> List A
       List B
```

```text
#ruby -> Home
       List A
       List B
```

In particular:

> **The existence of a TagFollow MUST NOT imply delivery to Home.**

Home delivery exists only when an explicit Home destination exists.

Any migration or implementation that creates a Home delivery merely because a
`TagFollow` exists is incorrect.

### 3.3 Do not import upstream Home/List product semantics by accident

Upstream/HomeTown-derived feed behavior may treat Home and Lists as related but
non-peer concepts, for example by excluding content from Home when an account is
present in a List.

That is not the Fedibird subscription model.

This project may adopt upstream data structures while retaining Fedibird routing
semantics in `FanOutOnWriteService`, `FeedManager`, and related code.

---

## 4. Target data model

### 4.1 Upstream relation: TagFollow

Use upstream Mastodon's relation as the canonical statement that an account
follows a hashtag:

```text
tag_follows
  id
  account_id
  tag_id
  created_at
  updated_at

UNIQUE(account_id, tag_id)
```

The Ruby model should converge on upstream `TagFollow` as closely as the
Fedibird branch permits.

`Tag` should use the upstream relationship shape:

```ruby
has_many :passive_relationships,
         class_name: 'TagFollow',
         inverse_of: :tag,
         dependent: :destroy

has_many :followers,
         through: :passive_relationships,
         source: :account
```

### 4.2 Fedibird extension: per-destination delivery

Do **not** add `list_id` directly to upstream `tag_follows`.

Doing so would destroy the upstream invariant that one
`(account_id, tag_id)` pair represents one follow relation and would force
upstream controllers and serializers to retain Fedibird-specific cardinality.

Instead add an extension table, working name:

```text
tag_follow_deliveries
  id
  tag_follow_id
  list_id          nullable
  media_only       boolean NOT NULL default false
  created_at
  updated_at
```

Semantics:

```text
list_id = NULL  => Home
list_id = N     => List N
```

Recommended constraints:

- foreign key `tag_follow_id -> tag_follows.id ON DELETE CASCADE`
- foreign key `list_id -> lists.id ON DELETE CASCADE`
- one Home destination per TagFollow:
  unique partial index on `tag_follow_id WHERE list_id IS NULL`
- one row per concrete List destination:
  unique partial/composite index on `(tag_follow_id, list_id)`
  where `list_id IS NOT NULL`

Active Record uniqueness on Home must use the same condition (`list_id IS
NULL`). Unscoped uniqueness on `tag_follow_id` would reject a valid Home row
when a List destination already exists.

No implicit delivery row is synthesized by the model merely because a
`TagFollow` exists.

### 4.3 Effective subscription invariant

In normal steady state a user-visible `TagFollow` should have at least one
delivery row.

If the final delivery row is removed through Fedibird destination-management
UI/API, the parent `TagFollow` should normally be removed as well.

This keeps upstream `following: true` aligned with the practical meaning
"this account receives this hashtag somewhere".

The database does not need to enforce this with a complex constraint; enforce
it at the service layer and verify it operationally.

---

## 5. Standard Mastodon API vs Fedibird destination management

The standard Mastodon hashtag-follow API operates on the upstream relation.
Fedibird-specific UI/API operates on delivery destinations.

### 5.1 Standard follow

`POST /api/v1/tags/:id/follow` has no destination parameter.

For backward compatibility with existing Fedibird behavior, it should:

1. find or create the upstream `TagFollow`
2. ensure an explicit Home `TagFollowDelivery` exists
3. leave existing List deliveries intact
4. return the upstream-compatible tag representation

Important case:

```text
before:
  TagFollow(#ruby)
    -> List A
    -> List B

standard follow request:

after:
  TagFollow(#ruby)
    -> Home
    -> List A
    -> List B
```

A pre-existing lists-only follow must not cause the standard follow endpoint to
be a no-op.

### 5.2 Standard unfollow

Target upstream contract:

`POST /api/v1/tags/:id/unfollow` removes the follow relation.

That implies deleting the `TagFollow` and all Fedibird delivery rows beneath
it.

Fedibird per-destination removal remains available through the Fedibird
destination-management surface.

**Before cutover, pin this behavior in request specs and explicitly confirm that
no supported Fedibird client relies on the current ambiguous behavior where
`FollowTag.find_by(...).destroy!` may remove only one of several destination
rows.**

### 5.3 Fedibird `/api/v1/follow_tags` compatibility surface

The existing Fedibird API is row-oriented and historically exposes
`FollowTag` records.

Do not silently remove this API as part of the model rename.

During the compatibility period, keep the route and adapt it to the delivery
model. Its external contract should be inventoried and frozen before changing
fields.

The server-rendered Settings UI should also continue to present one row per
destination:

- tag name
- media-only setting
- Home or concrete List
- edit/delete destination

Internal model names do not need to leak into this compatibility surface.

---

## 6. Feed-routing implementation boundary

### 6.1 Fan-out

Current Fedibird code directly queries:

```ruby
FollowTag.home ...
FollowTag.list ...
```

Target shape:

```text
TagFollow
  JOIN TagFollowDelivery
  JOIN Tag
```

Home fan-out selects account IDs from delivery rows with `list_id IS NULL`.

List fan-out selects list IDs from delivery rows with `list_id IS NOT NULL`.

`media_only` remains destination-specific.

Do not infer Home from `TagFollow`.

### 6.2 Visibility filtering

The current generic `visibility_scope(status, klass)` assumes the queried
class has an `account_id` column. `TagFollowDelivery` should not duplicate
`account_id` merely to satisfy that helper.

Prefer a tag-follow-specific relation that joins `tag_follows` and applies
visibility eligibility through `tag_follows.account_id`.

Avoid denormalizing `account_id` into the delivery table unless profiling
proves the join materially harmful.

### 6.3 FeedManager crutches

Current Fedibird uses `FollowTag` in `FeedManager#build_crutches` to answer
whether a status is admitted to the current Home/List destination because of a
hashtag subscription.

Preserve that behavior, but query:

```text
TagFollow(account = receiver)
  -> TagFollowDelivery(destination = current Home/List)
  -> matching tag_ids
```

The resulting crutch still means:

> this status has a followed hashtag **for this destination**

not merely:

> this account follows the hashtag somewhere.

That distinction is essential for lists-only subscriptions.

### 6.4 Other subscription models

Do not redesign `AccountSubscribe`, `DomainSubscribe`, or
`KeywordSubscribe` in this project.

They are evidence for the Home/List peer-destination invariant and may later
benefit from a shared routing abstraction, but extracting a universal
subscription framework is out of scope for this migration.

---

## 7. Phase A — FollowTag -> TagFollow structural unification

This phase deliberately does **not** change hashtag identity rules yet.

Keeping follower-model migration separate from tag-identity migration gives us
a reversible boundary before the destructive part of the project.

### A1. Preflight analyzer

Create a read-only analyzer before schema cutover.

It must report at least:

- total `follow_tags` rows
- distinct `(account_id, tag_id)` relations
- Home destination rows
- List destination rows
- relations with Home only
- relations with Lists only
- relations with Home + List(s)
- relations with multiple Lists
- duplicate source rows for the same `(account, tag, list_id)`
- conflicting `media_only` values among duplicates
- orphaned account/tag/list references, if any
- maximum number of destinations on one followed tag
- distribution of delivery counts per TagFollow

The analyzer must not modify production data.

### A2. Schema expansion

Add:

- upstream-compatible `tag_follows`
- `tag_follow_deliveries`

Do not remove or rename `follow_tags`.

Use migration patterns appropriate to the current Fedibird Rails/PostgreSQL
stack:

- avoid table-wide blocking operations
- use concurrent indexes where supported/required
- validate foreign keys separately if needed
- do not perform a large production backfill inside one schema migration

### A3. Idempotent backfill

For each distinct legacy:

```text
(account_id, tag_id)
```

create exactly one `TagFollow`.

For every legacy `FollowTag`, create the corresponding delivery:

```text
legacy list_id NULL -> Home delivery
legacy list_id N    -> List N delivery
legacy media_only   -> delivery.media_only
```

If historical races produced duplicate legacy rows for the same destination,
collapse them.

For conflicting `media_only` duplicates:

> **false wins**

Reason: if any legacy row had `media_only=false`, non-media statuses were
eligible for that destination. Choosing true would lose deliveries that were
previously allowed.

Recommended timestamp preservation:

- `TagFollow.created_at = MIN(source created_at)`
- `TagFollow.updated_at = MAX(source updated_at)`
- delivery timestamps use the corresponding source destination group

The backfill must be restartable and safe to run repeatedly.

### A4. Parity validator

Before runtime cutover, compare old and new representations.

Required invariants:

```text
distinct old (account, tag)
  == new tag_follows

distinct old (account, tag, destination)
  == new deliveries

old lists-only relation
  => new TagFollow with zero Home deliveries

old Home-only relation
  => exactly one Home delivery

old Home + N lists
  => one Home + N List deliveries
```

Also compare effective media eligibility destination by destination.

Do not cut over on count equality alone. Validate sampled semantic tuples.

### A4.1 Production backfill result

After U2 was deployed to the production database, the authoritative legacy
source had advanced by one row since the first analysis:

```text
legacy follow_tags rows       14,551
distinct (account, tag)       14,430
Home destinations             11,286
List destinations              3,265
```

The first real APPLY run created exactly:

```text
tag_follows                   14,430
tag_follow_deliveries         14,551
  Home                        11,286
  List                         3,265
```

Source integrity remained clean:

- duplicate destination groups: 0
- media_only conflict groups: 0
- null account/tag rows: 0
- orphaned List rows: 0
- List owner mismatches: 0

The backfill's post-write parity report was `ok: true`, with zero missing,
extra, or media-only-mismatched relations/destinations. A separate parity run
approximately 30 seconds later was also `ok: true`.

The fact that one new legacy relation appeared between the earlier analyzer run
and this production backfill is useful evidence: the migration does not depend
on a frozen historical count and can synchronize the live authoritative source.

### A4.2 U3a dual-write bridge

Before switching any reads, fan-out, API representation, or Settings UI to the
new structure, enable synchronous legacy-to-new mirroring on ordinary
`FollowTag` model writes.

During U3a:

- legacy `follow_tags` remains authoritative
- all reads continue to use legacy `FollowTag`
- successful model create/update/destroy mirrors the complete affected
  `(account_id, tag_id)` relation into `TagFollow` +
  `TagFollowDelivery`
- Home remains an explicit `list_id = NULL` delivery
- List-only remains List-only
- destination `media_only` remains per-destination
- deleting the final legacy destination removes the mirrored `TagFollow`
- moving a source row between account/tag relations synchronizes both the old
  and new relation
- mirror writes occur in the same database transaction as the legacy model
  write, so a mirror failure rolls the legacy write back rather than silently
  diverging the two representations

U3a deliberately does **not** change:

- standard hashtag follow/unfollow write semantics
- Fedibird `/api/v1/follow_tags` external behavior
- Settings UI
- FanOutOnWriteService
- FeedManager

U3b-1 later switched standard following-state **reads** to `TagFollow` while
leaving those write and delivery paths on legacy `FollowTag`.

Continue running the U2 parity task during this bridge. Raw SQL/bulk writes to
`follow_tags` do not run Active Record callbacks and therefore remain an
operational exception; rerun the U2 backfill/parity tools after any such
maintenance.

### A4.3 U3b-1 standard read cutover

U3b-1 is a read-only cutover of the upstream-compatible hashtag-follow
relation. It does not change writes or delivery routing.

Authoritative for standard following-state reads:

- `TagRelationshipsPresenter`
- `REST::TagSerializer#following`
- `GET /api/v1/followed_tags`

Authoritative for writes and timeline delivery, unchanged at U3b-1:

- `Api::V1::TagsController` follow/unfollow (`FollowTag` + U3a mirror)
- `/api/v1/follow_tags`
- Settings hashtag-follow UI
- `FanOutOnWriteService`
- `FeedManager`

U3b-2 later switched FanOut hashtag delivery and FeedManager tag admission to
`TagFollowDelivery` without changing those write/management surfaces.

`TagFollow` existence means the account follows the hashtag. It does **not**
mean Home delivery exists. A List-only relation therefore reports
`following: true` and appears once in `GET /api/v1/followed_tags`.

`GET /api/v1/followed_tags` paginates canonical `TagFollow` rows, not legacy
destination rows, so one account/tag relation with Home plus Lists is returned
once.

### A4.4 U3b-2 delivery/read-admission cutover

U3b-2 is a read-only cutover of **hashtag delivery and FeedManager tag
admission** from legacy destination rows to explicit `TagFollowDelivery`.

It does not change writes, and it does not change destination-management
resource IDs.

Authoritative for timeline delivery and feed tag admission:

- `FanOutOnWriteService#deliver_to_hashtag_followers_home`
- `FanOutOnWriteService#deliver_to_hashtag_followers_list`
- `FeedManager#build_crutches` → `crutches[:following_tag_by]`

Authoritative for writes and destination management, unchanged:

- `Api::V1::TagsController` follow/unfollow (`FollowTag` + U3a mirror)
- `/api/v1/follow_tags`
- Settings hashtag-follow UI
- legacy `follow_tags.id` as the management resource ID

Home delivery exists only when an explicit Home `TagFollowDelivery`
(`list_id` NULL) exists. List delivery exists only for that List's delivery
row. A bare `TagFollow` with zero deliveries delivers nowhere and does not
unlock reply admission.

Destination-level `media_only`, existing `visibility_scope`, and
`Status#tags_without_mute` remain in force. FanOut applies `visibility_scope`
to `TagFollow` (the relation that owns `account_id`) after joining
`TagFollowDelivery`.

`/api/v1/follow_tags` and Settings remain on legacy `FollowTag` because those
surfaces expose `follow_tags.id`. Backfilled `tag_follow_deliveries.id` values
are not guaranteed to match. That compatibility/resource-ID problem is U3b-3.

Rollback remains application-code-only while dual-write is retained:

```text
deploy problem
  -> revert application code to U3b-1
  -> FanOut/FeedManager read legacy FollowTag again
  -> legacy writes were never stopped
```

Before deploying U3b-2, administrators must run:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

and require `"ok": true`. After deploy, exercise real Home/List/`media_only`
mutations and rerun parity.

Recommended canary matrix:

- Home-only follow receives a tagged post only in Home
- List-only follow receives it only in that List
- Home + List receives both
- `media_only` blocks text-only and admits media
- removing Home while retaining List stops Home delivery but keeps List
- removing the final destination stops delivery

Then rerun parity and require `"ok": true`.

### A5. Runtime cutover

U3b-1 already switched standard following-state reads
(`TagRelationshipsPresenter`, `REST::TagSerializer#following`,
`GET /api/v1/followed_tags`) to `TagFollow`.

U3b-2 already switched hashtag Home/List delivery and FeedManager tag
admission to `TagFollowDelivery`.

Remaining cutover still includes:

- `Api::V1::TagsController` writes
- Settings hashtag-follow UI
- Fedibird `/api/v1/follow_tags` compatibility controller/serializer
- model associations on `Tag`, `List`, and account-related concerns

to `TagFollow` + `TagFollowDelivery`.

Where behavior is semantically identical, prefer upstream Mastodon source
rather than rewriting equivalent Fedibird code.

Where routing differs, keep a visibly Fedibird-specific extension.

### A6. Soak period and old table removal

Do not drop `follow_tags` in the same deployment that cuts reads/writes over.

Keep it for a defined soak period.

During the soak period monitor:

- new TagFollow count
- delivery count
- follows with zero destinations
- duplicate destinations
- fan-out error rates
- user-visible followed-tag counts
- Home-only / list-only parity samples

After the new path is proven authoritative, remove legacy code and then remove
`follow_tags` in a later migration.

Rollback remains comparatively straightforward until legacy data is removed.

---

## 8. Phase B — upstream hashtag identity and display semantics

This phase is intentionally separate because merging existing `Tag` identities
is much less reversible.

### 8.1 Target upstream semantics

Converge on upstream Mastodon v4.2 behavior:

```text
Tag#name
  canonical identity produced by HashtagNormalizer

Tag#display_name
  outward/display representation

Tag.normalize
  HashtagNormalizer.new.normalize(...)

find_or_create_by_names
  lookup/create by canonical name
  preserve cleaned raw representation as display_name
```

This removes the temporary hybrid state in PR #117 where Fedibird identity and
`display_name` equivalence use different rules.

Examples that become one identity:

```text
blahaj
BLÅHAJ
```

```text
synthwave
Ｓｙｎｔｈｗａｖｅ
```

### 8.2 Public display behavior

After identity cutover, align outward display code with upstream:

- public `REST::TagSerializer#name -> object.display_name`
- Admin Tag serializer should no longer need a Fedibird-only workaround solely
  to expose display name
- ActivityPub hashtag serializer uses `display_name`
- hashtag web pages and metadata use `display_name` for presentation
- internal lookup/routing continues using canonical `name`
- featured-tag presentation is aligned with upstream where compatible

This is the point at which PR #117's `display_name` column receives its full
upstream meaning.

### 8.3 Do not perform destructive merge before analysis

First produce a read-only canonicalization report.

For every existing Tag calculate:

```ruby
canonical_name = HashtagNormalizer.new.normalize(tag.name)
```

Report:

- total Tag rows
- number already canonical
- number requiring rename
- number of canonical collision groups
- number of Tag rows participating in collisions
- affected relationship-row counts by table
- largest collision groups
- largest groups by status usage

Export enough detail to inspect representative collisions:

```text
canonical_name
source_tag_ids
source_names
status counts
account association counts
featured counts
favourite counts
tag-follow counts
mute counts
```

No production mutation is allowed in the analyzer.

### 8.4 Canonical survivor rule

Use a deterministic rule.

Initial proposal:

1. canonical name = `HashtagNormalizer.normalize(source name)`
2. if the group contains a Tag whose current name is case-insensitively equal
   to the canonical name, prefer it
3. otherwise choose the lowest/oldest Tag id
4. preserve the survivor's pre-migration outward representation as
   `display_name` when it normalizes back to the canonical name
5. rename survivor `name` to the canonical value
6. merge all dependent references into the survivor

Because PR #117 is intentionally not deployed before this work, production
should not contain administrator-written `display_name` values originating
from #117. Still, the migration/analyzer must detect unexpected non-null values
and preserve only values that normalize to the same canonical identity.

Do not silently choose the prettiest or most-used spelling without an explicit
policy; that would make presentation depend on incidental traffic history.

### 8.5 Tables that require merge handling

At minimum the current schema requires handling for:

- `statuses_tags`
- `accounts_tags`
- `featured_tags`
- `favourite_tags`
- `tag_account_mutes`
- the new `tag_follows`

The final implementation must re-audit the schema immediately before migration
and fail closed if an unhandled Tag foreign key/reference exists.

### 8.6 Duplicate handling by relation

#### statuses_tags

The join is unique per status/tag.

For each losing Tag:

1. insert missing `(status_id, survivor_tag_id)` links
2. ignore already-present survivor links
3. delete losing links

Never update blindly into a unique-key collision.

#### accounts_tags

Use the same insert-missing/delete-losing pattern.

#### favourite_tags

After Tag merge, one account may have multiple favourite-tag rows for the same
canonical Tag.

Collapse deterministically and preserve a single surviving relationship.

#### tag_account_mutes

Collapse to one `(account_id, canonical_tag_id)` relation.

#### tag_follows

If two previously distinct Tag identities collapse for one account:

1. choose/create one canonical `TagFollow`
2. union all delivery destinations from the duplicate follows
3. for duplicate destination conflicts, `media_only=false` wins
4. delete losing `TagFollow` rows only after delivery parity is verified

A lists-only subscription must stay lists-only unless one of the source follows
had an explicit Home destination.

#### featured_tags

This requires special care because counters can overlap after Tag merge.

Do not simply add `statuses_count` values.

Collapse duplicates per account/canonical Tag, then recompute/recount from the
canonical Tag relationship.

Fedibird-specific remote featured-tag URL behavior and its higher configured
limit are separate product extensions and must not be accidentally removed when
bringing the model closer to upstream.

### 8.7 One-way boundary

Tag identity consolidation is not fully reversible once duplicate join rows are
collapsed because the old provenance is intentionally erased.

Therefore:

- run the analyzer against a production-sized copy first
- retain an explicit old->canonical mapping/audit artifact during migration
- take/verify a database backup before the destructive merge
- rehearse elapsed time and lock behavior
- define a maintenance window if online correctness cannot be proven
- do not advertise rollback through ordinary Rails down migrations after the
  destructive boundary

A safe operational stop-before-merge is preferable to a clever but unproven
zero-downtime rewrite.

---

## 9. FeaturedTag convergence

Featured tags also diverged historically.

Upstream v4.2 has a stored `featured_tags.name` and exposes
`display_name`; current Fedibird retains older behavior plus Fedibird-specific
features such as remote URL handling and a different local limit.

Treat these separately:

### Upstream-compatible behavior to adopt

- normalized Tag identity lookup
- display-name presentation
- upstream-compatible serializer value formats where they are part of the API
  contract
- uniqueness based on canonical Tag identity

### Fedibird behavior to retain deliberately

- remote featured-tag URL support where still required
- Fedibird's intentional featured-tag limit unless separately decided
- any federation behavior required by current Fedibird remote featured-tag
  support

Do not replace the whole Fedibird model blindly with the upstream file.

---

## 10. Migration safety and operations

### 10.1 No giant schema/data transaction

Large relationship rewrites must not run as one blocking Rails migration.

Use:

- schema expansion migrations
- post-deployment/batched data tasks where appropriate
- restartable operations
- bounded batches
- explicit progress logging
- verification between phases

### 10.2 Read-only analysis comes first

No production data migration should be written until the analyzers establish
real cardinalities and collision sizes.

Do not invent operational thresholds in advance.

### 10.3 Idempotency

Every backfill step must be safe after interruption.

Prefer insert/upsert-if-missing and explicit checkpoints over "run once and
hope".

### 10.4 Foreign keys and indexes

Add indexes/FKs using repository-safe migration practices.

Do not add a large validated foreign key or blocking unique index without
considering existing table size.

### 10.5 Audit artifacts

For destructive Tag merge, retain at least:

```text
old_tag_id
old_name
canonical_tag_id
canonical_name
decision/reason
```

until the migration has been operationally accepted.

This is an audit/debug aid, not a permanent second identity system.

---

## 11. Required behavioral regression matrix

### 11.1 Tag-follow destinations

Pin all of these:

1. Home only
2. one List only, no Home
3. multiple Lists only, no Home
4. Home + one List
5. Home + multiple Lists
6. different `media_only` per destination
7. deleting one List destination leaves other destinations intact
8. deleting Home leaves List-only subscription intact
9. deleting the final destination removes the effective follow relation
10. deleting a List cascades/removes only that destination
11. standard follow on a lists-only relation adds Home without deleting Lists
12. standard unfollow follows the explicitly chosen upstream-compatible
    relation contract
13. `following` is true while any effective destination exists
14. no code path infers Home from TagFollow existence

### 11.2 Fan-out

For the same followed hashtag verify independently:

- Home receives only when Home destination exists
- each configured List receives
- unconfigured Home does not receive
- unconfigured Lists do not receive
- `media_only` filters per destination
- visibility rules are unchanged
- reply admission through hashtag subscription remains destination-aware
- block/mute/domain filtering remains unchanged

### 11.3 Tag identity

Pin:

- case normalization
- ASCII folding
- CJK/full-width normalization
- invalid character stripping
- canonical lookup
- collision merge
- no duplicate status/tag joins
- no duplicate account/tag joins
- TagFollow destination union during collision
- favourite/mute dedupe
- FeaturedTag recount behavior

### 11.4 Serialization/federation

Pin:

- public REST tag display name
- Admin tag shape
- followed-tags API
- tag follow/unfollow API
- ActivityPub hashtag name
- featured-tag REST representation
- hashtag URL continues to use canonical identity/routing behavior

---

## 11.5 Observed production-scale data (2026-09-19)

The first read-only analysis was run against a production-scale database copy.

### FollowTag shape

Observed:

- 14,550 legacy `follow_tags` rows
- 14,429 distinct `(account_id, tag_id)` relations
- 11,194 Home-only relations
- 3,144 Lists-only relations
- 91 Home + List relations
- 30 multi-List relations
- maximum two destinations per relation
- zero duplicate destination groups
- zero `media_only` conflicts
- zero orphaned account/tag/list references

This confirms that Lists-only hashtag following is a major real-world Fedibird
use case, not an edge case. A `TagFollow` must therefore never synthesize Home
delivery implicitly.

The structural migration target is expected to be approximately:

```text
14,550 FollowTag rows
    -> 14,429 TagFollow rows
    -> 14,550 TagFollowDelivery rows
```

subject to re-verification immediately before backfill.

### Tag canonicalization shape

Observed:

- 7,126,482 Tag rows
- 617,958 names would change under upstream `HashtagNormalizer`
- 29,474 canonical collision groups
- 59,827 Tag rows participate in collisions
- maximum collision group size: 14
- therefore 30,353 losing Tag rows if every collision group is reduced to one
  survivor
- no `display_name` values had yet been persisted in the analyzed dataset

Collision-participating Tags are referenced by more than 20 million
`statuses_tags` rows. That number is intentionally **not** treated as the
number of rows that must be rewritten: it includes references already attached
to the eventual survivor Tag.

Before the destructive migration is designed, a second read-only planner must
select the deterministic survivor for every group and separately measure:

- references already on the survivor
- losing references that can be repointed
- resulting unique-key collisions that must be deduplicated
- FeaturedTag relationships requiring recount
- FollowTag/TagFollow destination merges and `media_only` conflicts

This planner is the U0.1 step between the broad collision analyzer and the
write migration.

---

## 12. Proposed PR / deployment decomposition

Keep individual changes reviewable even though they belong to one coordinated
project.

### PR U0 — design + analyzers

- this design document
- read-only FollowTag migration analyzer
- read-only Tag canonicalization/collision analyzer
- no runtime behavior change

### PR U1 — relation schema expansion

- upstream `TagFollow` table/model
- `TagFollowDelivery`
- associations and isolated model specs
- no runtime read cutover
- no legacy table removal

### PR U2 — FollowTag backfill + parity tooling

Implementation rules:

- source of truth remains legacy `follow_tags` during U2
- backfill is idempotent and may be rerun
- one `TagFollow` is upserted per distinct `(account_id, tag_id)`
- one explicit delivery row is upserted per legacy destination
- `list_id = NULL` maps only to an explicit Home delivery
- duplicate legacy destinations are collapsed
- conflicting `media_only` values use `BOOL_AND` / false-wins semantics
- source rows are never deleted or modified
- List ownership mismatches and null account/tag source rows are hard blockers
- parity compares relations, destinations, and `media_only` values in both directions
- U2 does not prune target-only rows automatically; a non-zero parity diff must be understood before cutover

Because runtime still writes only legacy `FollowTag` in U2, a production
backfill may become stale immediately after it runs. Re-running is safe. The
final parity check for U3 must occur under a write-quiescent or dual-write
cutover procedure; do not infer authoritativeness from one historical backfill.


### PR U3 — runtime TagFollow cutover

U3 is staged. U3a dual-write, U3b-1 standard read cutover, and U3b-2
hashtag delivery/read-admission cutover are complete.

Remaining U3 work still includes:

- Settings/API destination-management adapters (`/api/v1/follow_tags`, Settings)
- write-path cutover off legacy `FollowTag`
- old `follow_tags` retained

### PR U4 — legacy follow cleanup

After production soak:

- remove old runtime paths
- remove `FollowTag`
- later remove `follow_tags`

### PR U5 — Tag identity readiness

- canonicalization analyzer finalized against real data
- upstream Tag semantics introduced behind migration-safe boundary as needed
- collision mapping/rehearsal tooling
- no destructive production merge until report approved

### PR U6 — canonical Tag data migration + source cutover

- merge existing identities
- remap/dedupe all dependent data
- enable upstream `Tag.normalize` / `find_or_create_by_names`
- upstream public display semantics
- FeaturedTag alignment
- explicit operational runbook

This PR/release may require a maintenance window depending on measured data.

### PR U7 — cleanup

- remove temporary compatibility/mapping code
- remove dead Fedibird forks that are now upstream-identical
- document the remaining intentional Fedibird patch surface

The exact PR count may change, but do not collapse the reversible FollowTag
migration and irreversible Tag identity merge into one unreviewable operation.

---

## 13. Acceptance criteria

The project is complete when all of the following are true.

### Source structure

- `Tag` identity and `display_name` semantics match the target upstream
  Mastodon version.
- canonical hashtag-follow relation is upstream `TagFollow`.
- there is no duplicate Fedibird `FollowTag` relation model.
- upstream-equivalent controllers/serializers are upstream-shaped where
  practical.
- Fedibird differences are small and explicitly named.

### Product behavior

- Home/List peer-destination semantics are preserved.
- lists-only hashtag subscriptions remain lists-only.
- multi-list subscriptions remain possible.
- per-destination `media_only` behavior is preserved.
- other Fedibird subscription features are not changed by this project.

### Data

- no followed hashtags are lost.
- no destinations are silently added or removed.
- no Home destination is synthesized from relation existence.
- no status/tag relationship is lost during canonicalization.
- canonical collisions are merged deterministically.
- all Tag-dependent tables have an explicit migration rule.
- post-migration orphan/duplicate validators pass.

### Operations

- migration has been rehearsed on production-scale data.
- irreversible boundary is explicitly called out.
- rollback is defined for every phase before that boundary.
- database backup/recovery procedure is verified before destructive Tag merge.

---

## 14. Immediate next steps

1. Merge PR #117 after restoring any unrelated weakened pre-existing regression
   spec; do not deploy #117 alone.
2. Keep this work based on #117 so `display_name` and Admin Tags API are
   available as the migration foundation.
3. Implement **read-only analyzers first**.
4. Use analyzer results, not assumptions, to size the data migration.
5. Implement Phase A (TagFollow structural unification).
6. Verify/soak Phase A before beginning destructive Tag identity consolidation.
7. Re-run a zero-based review against the actual migration code before any
   production deployment.

---

## 15. Design principle to carry forward

The purpose of this work is not merely to delete old classes.

The useful outcome is a repository where a future maintainer can answer:

> "Is this line upstream Mastodon behavior, or an intentional Fedibird
> extension?"

without reconstructing years of fork history.

For the hashtag subsystem, the intended answer should become:

```text
Identity, REST model, basic follow relation:
    upstream Mastodon

Destination routing, Home/List peer semantics, media-only delivery:
    explicit Fedibird extension
```

That is the architectural target.
