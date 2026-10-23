# External status visibility

Parent plan: issue #541. The sections through "Deploy and verification" are the E1 slice, issue #542. E2, issue #544, is the storage switch and the forward migration. It is specified in the E2 section of this document and in `docs/external_status_visibility_migration.md`.

Related contracts, which this document does not replace:

- `docs/private_external_bridge.md` — P0 architecture. Its projection contract still describes `visibility = personal` as the production shape.
- `docs/private_external_bridge_audit.md` — baseline code-path audit. Its CONFIRMED, RISK, and GAP rows are that baseline. They are not a description of the E1 tree.
- `docs/external_feed_routing.md` — E3-A home/list routes and REST merge. Streaming is not part of it. The delivery flag ships off.

E1 is a read and protection foundation. It does not switch the writer, migrate existing rows, deliver external rows to home or lists, accept `unlisted` as the public compatibility value, publish a link Note, or perform a native AT Protocol action.

## Decision

`Status.visibility` gains one internal value: `external: 201`.

| Name | Integer | Role |
| --- | --- | --- |
| public | 0 | unchanged |
| unlisted | 1 | unchanged |
| private | 2 | unchanged |
| direct | 3 | unchanged |
| limited | 4 | unchanged |
| mutual | 100 | unchanged |
| personal | 200 | unchanged for ordinary posts. Legacy projections stay here until an operator migrates them. New projections stay here while the E2 switch is off. |
| external | 201 | internal. External content that only the owning User may read. |

Numeric order is not authorization. `external` is not a searchability. Both the legacy projection and a canonical external row keep `searchability = personal`. `set_searchability` does not copy 201 into that column.

`external` means “external content, visible only to me”. It is not an external account connection and it is not an ActivityPub remote status.

`external_projection` and `external_status_projections` stay. They are not replaced by the enum.

## What E1 implements

- The enum, the exclusion from account post counts, and the refusal to treat `external` as a composable visibility.
- One privacy predicate in Ruby, SQL, and the batched decision: a row is private when `visibility` is external, or `external_projection` is true, or a marker exists.
- Read permission only when that marker’s `user_id` equals the authenticated `User.id`. The same `Account` with a different `User` is denied. `Account`, `Account#user`, and an admin role are not substitutes. A missing marker denies everyone, including the account holder.
- Database guards that accept a marker on visibility 200 or 201, keep field immutability, and check the external insert shape. Personal rows are not updated to external.
- REST for a canonical external row: `visibility=direct`, `visibility_ex=external`. Legacy projections and ordinary personal posts stay `visibility=direct`, `visibility_ex=personal`.
- WebUI label 「外部コンテンツ（自分専用）」 / “External content (only you)” on the status, the detailed status, and the boost-modal icon map. Reply, boost, quote, edit, redraft, pin, and visibility change stay unavailable.
- Normal POST, PATCH, scheduled create, reblog visibility, posting-style validation, search operators, and timeline filters reject the token `external` and the integer 201.

## What E1 left open

E1 did not switch the writer or migrate rows. E2 now does those two things, and only those, under an operator switch that ships off. The rest of this list stays open under #541:

- E1's `ProjectionWriter#create!` inserted `visibility: personal` only. E2 reads `external_bridge_external_visibility`. Off still inserts personal. On inserts external. The switch does not rewrite existing rows.
- E1 rejected every personal-to-external update. E2 adds one transaction-local permit for a single projection status. There is still no GUC that disables the guard, and no path back from 201 to 200.
- Home and list REST delivery for a canonical external row is a separate contract in `docs/external_feed_routing.md` (E3-A). It ships off and does not change streaming. The personal timeline still requires `visibility = personal`, so an external row does not join it.
- No change of the public compatibility mask from `direct` to `unlisted`.
- No public link Note, no boost or reply or quote of the external body, no native AT Protocol write.
- No new statuses column, default, backfill, or statuses index.
- RSS and AT Protocol feature flags and tester allowlists are unchanged.

A canonical external row can be inserted by the test helper, in one transaction, as status then marker. Production RSS import does not do that.

## Records

```
ExternalSource ── ExternalResource ── ExternalStatusProjection ── Status
                       │                      │                    │
                       └── ExternalSubscription (user_id) ─────────┘
                                              │
                                            User
```

| Record | E1 rule |
| --- | --- |
| ExternalSource / ExternalResource | Shared fetch data. Not a permission. |
| ExternalSubscription | Belongs to one User. The other User of the same Account does not see it. |
| ExternalStatusProjection | `user_id` is the only reader. `status_id` is unique. |
| Status | Legacy production shape: `external_projection=true`, `local=true`, `uri=nil`, `visibility=personal`, `searchability=personal`, no reply, reblog, or quote. Canonical external fixture: the same, with `visibility=external`. |
| ActivityPub Note | Not created. `uri` stays nil. Serializing a private row raises `Status::UnreleasedActivityObject`. |
| Public link Note | Not this status. Not implemented. |

The status insert and the marker insert share a transaction. Visibility or the flag alone is enough to skip URI minting, webhooks, and fan-out, including the moment before the marker exists. After commit, a row with any one of the three signals stays private.

## Read predicate

```
private?(status) = visibility is external
                OR external_projection is true
                OR a marker exists for status.id
allow?(user, status) = a marker exists AND marker.user_id = user.id
```

`NOT_PROJECTION_SQL` is the negation of the private predicate. `PERSONAL_VISIBILITY_SQL` is that negation, or a marker owned by the viewer. `PersonalFeed` still also requires `visibility = personal`, so the owner’s external rows do not appear on the personal timeline. Favourite and bookmark lists use the visible relation without that extra filter, so the owner’s own rows can appear there.

`ProjectionAccess.prepare!` and `Decision` still load markers with one indexed read per page. Ordinary posts do not gain a per-status query. A private row is removed before a serializer sees it.

Paths that already call `private_status?`, `private_target?`, or `NOT_PROJECTION_SQL` follow the new predicate without a second copy of the rule. That includes fan-out, publish, distribution and update workers, removal, TagManager URL and URI, the Note serializer, link crawl, preview cards, push, backup, profile and outbox scopes, oEmbed, admin trend approval, Chewy `index_scope`, and favourite, unfavourite, and bookmark services.

E1 also closes reads that named only `personal` or only the flag:

- `StatusPolicy#show?` and `#reblog?` use the private predicate. `#update?` refuses `external` so the edit API is 403. A legacy projection still reaches `UpdateStatusService` and fails there.
- `search_indexable?` and the Chewy `delete_if` treat external visibility as not indexable, without a marker query on the indexable check.
- `store_uri` and the webhook callbacks use the side-effect helper, which is true for external visibility or the flag, and otherwise for a marker.
- REST masks `personal` and `external` to `direct`. `visibility_ex` is the raw enum. `fedibird_external` is present only when `allow?` is true, and it still says `local_only`.
- The status source action returns 404 when the row is hidden, including for the other User of the Account.
- Composer, posting styles, search operators, timeline seek, and reading-bookmark context use `composable_visibility_keys`, which omits `external`.

## Operation matrix

| Action | Marker owner | Other User, same Account | Stranger, anonymous, admin |
| --- | --- | --- | --- |
| GET status | 200, `direct` + `visibility_ex=external` | 404 | 404 |
| Favourite / bookmark and the reverse | allowed, no delivery, no trend | 404 | 404 |
| Subscription item list | canonical URL for that User’s subscription | 404 | 404 |
| Personal timeline | legacy projection and ordinary personal only | ordinary personal only | no projection text |
| Reply, boost, quote, pin, emoji reaction | refused | 404 | 404 |
| Edit text or visibility | 403 | 404 | 404 |
| Delete | owner purge, no ActivityPub delete | 404, row remains | not this account’s row |
| POST `visibility=external`, `visibility_ex=external`, or `201` | 422, no status | 422 | 422 |

Ordinary public and ordinary personal posts keep their previous policy, timeline, and counts. A legacy projection still reads as `visibility_ex=personal`.

## Database

New migration: `db/migrate/20261021140000_accept_external_visibility_projection_guards.rb`.

It does not run `Schema::DEFINITIONS_SQL`. That statement drops and revalidates the composite foreign keys and is only for `schema:load`. Migration `up` replaces the marker, field-guard, and shape functions, then drops and recreates two triggers: the field guard, and `statuses_external_visibility_shape_guard`.

`CREATE OR REPLACE FUNCTION` does not change an existing trigger's `UPDATE OF` list. The field-guard trigger is recreated so `local` and `reply` are in that list. The shape trigger is `BEFORE INSERT OR UPDATE OF local, reply`. Replacing those two triggers takes `ACCESS EXCLUSIVE` and does not rewrite `statuses`. `lock_timeout` is 5 seconds so a busy table fails the migration instead of waiting. The other triggers and the composite foreign keys stay in place.

Marker insert requires `external_projection = true` and `visibility IN (200, 201)`, plus the existing user, account, source, and subscription checks.

Field guard fires when the old or new flag is true, the old or new visibility is 201, or a marker exists. It still rejects account, visibility, searchability, URI, flag, deletion, reblog, `in_reply_to_id`, and quote changes. When the old or new visibility is 201 it also rejects `local` and `reply` changes. A personal-to-external update is a visibility change, so it is rejected. A text revision does not mention those columns, so it is not blocked. E1 does not add a bypass.

Shape for visibility 201: flag true, URI null, searchability 200, local true, reply not true, no reblog, reply, or quote id, `deleted_at` null. The model checks that shape on create and on update. The insert trigger rejects a raw insert. An update of `local` or `reply` on a visibility 201 row is rejected by the shape trigger and by the field guard. Ordinary public and personal rows, and a legacy projection's text revision, are not rejected by those checks.

`down` is fixed SQL in the migration file, not a call back into the current schema constant. It raises `check_violation` when any `statuses.visibility = 201` row exists, then restores the pre-E1 marker and field functions, recreates the field-guard trigger without `local` and `reply`, and drops the shape trigger. It does not touch composite foreign keys. A database that already stores external rows cannot silently return to the personal-only check.

`db/schema.rb` records the migration version and still executes `Schema::DEFINITIONS_SQL` at the end. Do not replace that file with an unconstrained `schema:dump`: Rails 6.1 rewrites emoji reaction `INCLUDE` indexes into ordinary three-column indexes. The dump probe writes to a separate `SCHEMA` path.

Hard purge, marker-delete protection, `users.account_id` protection, and the composite foreign keys stay.

## REST and WebUI

| Row | `visibility` | `visibility_ex` |
| --- | --- | --- |
| Legacy personal projection | direct | personal |
| Canonical external | direct | external |
| Ordinary personal | direct | personal |

The mask is computed per request. Status JSON is not a shared cache that could mix two viewers. `fedibird_external` is omitted unless the viewer is the marker owner. It keeps the existing source fields and `interaction: local_only`.

The WebUI normalizer sets client `visibility` from `visibility_ex` when that field is present, so the signed-in owner’s client shows the external label. Reply, redraft, and edit copy that value through `composerPrivacy`, which falls back to the user’s default instead of storing `external`. The privacy dropdown list is unchanged and does not contain `external`. `canEditStatus` is false. The reply, reference, reaction, redraft, and expire actions are not offered. Favourite, bookmark, and delete stay on the owner’s own menu. Delete still follows the server purge rules.

## Deploy and verification

Order:

1. Deploy this revision to every web, Sidekiq, and related worker process, and run the migration.
2. Confirm readers and the database guards know visibility 201. Production RSS saves are still personal.
3. A later PR, E2, may switch the writer and migrate projection rows. Do not do that in the same release as the first reader deploy.

Gates before E2:

- Owner GET, favourite, and bookmark of a canonical external fixture. Same-account User, stranger, anonymous, account-only, and admin denied. Missing marker denied to the owner.
- Legacy projection and ordinary personal and public rows unchanged.
- POST and PATCH cannot create or relabel `external`.
- No URI, webhook, Redis fan-out, ActivityPub delivery, search document, backup id, or account status count for the private body.
- Migration `up` is idempotent. `down` refuses when a 201 row exists and restores the old functions only inside a rolled-back probe when none exist.
- Scratch `schema:dump` / `schema:load` keeps the functions, the shape trigger, and the composite foreign keys, and does not rewrite the committed `INCLUDE` indexes.
- Marker reads for a page of 20 ordinary ids and a mixed page of legacy plus external stay flat. `EXPLAIN` of the new predicate on a small database is evidence about that database only, not production performance.
- If Elasticsearch is not reachable, the document-drop example is pending. Pending is not a pass.

E1 does not enable a flag and does not change how a new RSS item is stored.

## E2 storage switch and forward migration

E2 is issue #544. The runbook with the commands and the rollback floor is `docs/external_status_visibility_migration.md`.

`external_bridge_external_visibility` defaults to false in `config/settings.yml`. It is not an RSS or AT Protocol feature flag, not a tester allowlist, not a user preference, and not a key on the admin settings form. An operator sets it from a console. Turning it off does not rewrite rows that are already external. Turning it on does not migrate existing rows. RSS refresh of an existing projection updates the marker and the text and leaves visibility alone.

`ProjectionWriter#create!` is the only writer that reads the switch. It does not take a visibility argument. When the switch is on and this database has no external shape guard, the insert fails and does not fall back to personal or public. Normal posts, the post API, and the composer still reject `external`.

The new migration `db/migrate/20261021180000_permit_external_visibility_projection_transition.rb` replaces the field-guard function and adds `external_visibility_migrate_status(bigint)`. It does not run `Schema::DEFINITIONS_SQL`, does not drop foreign keys, and does not add a statuses column or index. `schema:load` installs the same functions because `DEFINITIONS_SQL` now includes them. The E1 migration constant `GUARD_REFRESH_SQL` stays the pre-transition guard, so re-running that historical migration does not install the permit. E2's `up` installs it afterwards.

The permit is the string `status_id || ':' || txid_current()` in the transaction-local setting `fedibird.external_visibility_migration`. The migrate function reads the caller's current value, sets the token for the update, and writes the previous value back before it returns. On an error or a query cancel it restores that same value and raises again. The function does not use a `CREATE FUNCTION SET` clause. PostgreSQL checks superuser or parameter SET privilege for that clause, and a normal database owner does not have it. An empty string left by resetting an unset custom placeholder is not a permit. The trigger still checks every condition. A matching token is not enough:

- old visibility 200, new visibility 201, and no other direction
- both images have the projection flag, `local`, null URI, searchability 200, reply not true, no reply, reblog, or quote id, and null `deleted_at`
- `to_jsonb(old) - visibility - updated_at` equals the same expression for the new row, so text, owner, `created_at`, `edited_at`, and every other column stay put. `updated_at` may move so `status.cache_key` changes
- one marker, and the user, status, and marker account ids match, as do the subscription user and source and the resource source

`down` restores the E1 field guard and drops the migrate function. It does not convert 201 rows back to 200 and it does not refuse because those rows exist. E1's own `down` still refuses while any 201 row exists. The rollback floor for application code is E1.

### Cache

`CacheConcern#cache_collection` only preloads. REST status JSON is built per request, and `visibility_ex` is the enum on that row. ActivityPub `render_with_cache` keys include `status.cache_key`, which includes `updated_at`. A private row is not distributable, so that cache is not a projection body. The migration still updates `updated_at` and, after commit, deletes the Rails cache key `statuses/#{id}` for each id in the batch. That key is deleted by purge and account deletion. No current writer was found. Processing, circle, and published Redis keys are left alone. The command does not publish `status.update`, clear the Rails cache, rebuild feeds, or reindex the cluster. If Chewy is enabled, the same batch bulk-deletes only those ids in slices of 100 and checks each bulk item and a following GET before the checkpoint advances. Success is a deleted item, or a response that names that document as missing. A missing index, a proxy 404, or any other 404 leaves the batch pending. The `:custom_sidekiq` strategy is not used for this follow-up, because it would remember the ids without deleting them. An open WebUI can keep the old personal label until the person reloads. Home and lists still do not receive the row.

### What a person sees

| State | Standard visibility | visibility_ex | Personal timeline |
| --- | --- | --- | --- |
| Ordinary personal post | direct | personal | unchanged |
| Legacy external projection | direct | personal | still on the owner's personal timeline |
| Migrated or newly stored external | direct | external | not on the personal timeline |

The subscription item list, the status itself, and the owner's favourites and bookmarks still open the same id. Another User of the same Account does not. E3 is not in this revision, so home, lists, and streaming do not gain the row, and there is no public link note.
