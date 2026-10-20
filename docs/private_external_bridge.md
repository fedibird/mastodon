# Private external-resource bridge

Status of this document: **P0 architecture and contract**. It does not add tables, models, workers, OAuth, UI, or federation behavior. The code-path evidence is in `docs/private_external_bridge_audit.md`.

Baseline inspected: `f583dd2a795f7e66dc3971c6b9203bda2f2fd69a` on `fedibird`.

Related designs, which this document does not replace:

- `docs/external_services.md` — connection hub and provider registry. A connection is not a credential.
- `docs/user_external_credential_vault.md` — ciphertext, owner binding, and job-argument rules.
- `docs/status_activity_object.md` — `post_title` and `ap_object_type` (`note` / future `page` only).
- `docs/personal_deepl_translation.md` — the existing per-user cache partition pattern.

This bridge links a Fedibird user to external resources and, when they choose, to an external account they already have. Fedibird does not host an AT Protocol PDS, does not mint hybrid ActivityPub+AT identities, and does not migrate accounts between those networks.

## Invariants

1. **Private projection by default.** An imported feed item or external post is visible only to the user who imported it. There is no shared synthetic actor, no instance-wide status, and no automatic ActivityPub relay. Two users following the same feed have two projections, two favourite rows, and two bookmark rows. Neither user can observe that the other subscribed.
2. **Shared fetch, never shared social state.** A fetch with no credential may be cached once and reused. Credentials, subscription membership, read state, annotations, and interactions are stored per user. P1 through P3 accept public fetches only. An authenticated or follower-only fetch is rejected and writes nothing to the shared tables, including ETag, HTTP status, and error bodies. A private resource identity is not this document's blob table; it is a later model with its own keys.
3. **Local Status compatibility without a public object.** The owner may see a projection through existing status surfaces. That row is not an ActivityPub object. Its URI stays null. `visibility = personal` is not a sufficient guard: `StatusPolicy#owned?` compares `account_id`, and several fan-out paths do not check `personal` themselves. See the audit.
4. **Public text only when the user publishes a different status.** A federated share is a new Note on the user's real local account. Its body is at most an optional title line, a protocol label, and the canonical URL. It does not contain the external article or post text, its media, or an actor pretending to be the external author. The private projection's id is never that Note's `id`.
5. **Native actions use the user's own external account.** A Fedibird favourite is not a Bluesky like unless the user has connected an identity, the provider capability allows it, and the user opts in for that action. Local state and the remote call fail separately. Missing or revoked credentials produce a failure, not a pretended success.
6. **Inbound activity stays private.** Replies, likes, and reposts from the native service are stored for the owning user only. They keep the native protocol and the native actor, object, and activity ids. They do not create ActivityPub activities, remote `Account` rows, or public notifications.
7. **No cross-user engagement surface.** Nothing ranks, counts, or lists other users' private reads, favourites, bookmarks, or comments on an external resource. A public link Note the user actually authored may enter the existing preview-card trends under the existing public-status rules. A projection cannot.
8. **Identities are not inferred.** Feed+GUID, AT URI+CID, the projection id, the ActivityPub URI, and the native activity id are different keys. Matching text or URLs does not merge objects or close a bridge loop.
9. **Least privilege.** Secrets stay in the vault. Jobs carry ids and classification, never tokens. X and mixi2 are not implemented until a later issue records an API and terms review.

## Terms

| Term | Meaning |
| --- | --- |
| Provider | A registry entry such as a future Bluesky page. DeepL is the only provider implemented today. |
| Connection | The user-facing relationship with a provider. Metadata lives on `external_identities`, not on the credential row. |
| Credential | Ciphertext in `user_external_credentials`, opened only through `UserCredentialVault`. |
| External source | A public feed or native actor that can be fetched. |
| External resource | One item from a source: an RSS entry or one AT Protocol record. |
| Projection | The owner's private status-shaped view of one resource. |
| External actor | Public author metadata (DID, feed identity, handle, byline). Not an `accounts` row. |
| Native identity | The owner's linked account on a provider, plus an optional vault credential. |
| External activity | One outbound native action and its delivery state. |
| Inbound interaction | One native reply, like, or repost addressed to the owner, stored privately. |
| Publication group | An explicit mapping the user created between their own Fedibird post and their own native posts. |
| AP reference | A normal local Note the user published, containing only the link template below. |
| Auxiliary parent | An AP reference used as `inReplyTo` or quote target. Reused only inside one distribution scope. Distinct from a standalone share and from a boost wrapper. |
| Distribution scope | The visibility and, for direct or limited, the recipient set of a reference Note. Auxiliary parents are unique per user, resource, and this scope. |
| Fediverse boost | `Announce` of the owner's reference Note by the owner's real account. Never `Announce` of the external URL or the private projection. |

## Three records, three audiences

```text
public fetch                         owner only                         owner's real actor
─────────────────────────            ─────────────────────────          ─────────────────────────
external_sources                     external_subscriptions             external_ap_references
external_resources                   external_status_projections        statuses row (real Note)
external_actors                      favourites / bookmarks             ActivityPub Create, or
(no user_id, no token,               inbound_interactions               Announce of that Note
 public responses only)              external_activities
                                     publication_groups

        │                                    │                                    │
        │  copy public fields into           │  never used as an AP object id    │  never points at the
        └──────── the projection ────────────┴────────────────────────────────────┘  projection row
```

The shared side answers "what is this public object?" The owner side answers "what did this user do with it?" The ActivityPub side answers "what did this Fedibird account choose to publish?"

A second user fetching the same public feed reads the same `external_resources` row and writes a different projection. Their favourite does not increment the first user's `status_stat`, and it does not increment a column on `external_resources`.

## Why the projection is not a synthetic account

`StatusPolicy#owned?` is `author.id == current_account&.id` (`app/policies/status_policy.rb`). A shared synthetic account would make every projection on that account visible to anyone acting as that account, and a per-user synthetic account would be a local actor: `Account#local?` is `domain.nil?`, local actors are Webfinger-discoverable, and `FanOutOnWriteService` calls `status.account.user` while delivering. `users.account_id` is indexed and is not unique (`db/schema.rb`, `index_users_on_account_id`).

The projection status uses the **owner's real local account** as `statuses.account_id`. That account is where the row has to live so existing status clients can address it. It is not the security principal. `external_status_projections.user_id` is the principal. Account equality is not enough to read the row, because more than one `users` row can point at the same `account_id`. The next section is the read rule.

External authors are `external_actors` rows. They are not followable, not Webfinger subjects, and not `Account.protocol` values. `Account.protocol` remains `ostatus` or `activitypub`. There is no `statuses.protocol`. `ap_object_type` remains `note` or a future `page` and is not reused.

Stock Mastodon clients will show the owner's account on the projection, because that is `status.account`. That mis-attribution stays on the owning user's own sessions: the projection is never federated. The Fedibird client reads the owner-only `fedibird_external` extension below. Creating a phantom actor so that stock clients show the external display name is out of scope. This is a review decision; the default is no phantom actor.

## Viewer is the User, not the Account

`Account` declares `has_one :user` (`app/models/concerns/account_associations.rb` line 8). `users.account_id` is indexed and is not unique (`db/schema.rb` line 1824, `index_users_on_account_id`). A second `users` row with the same `account_id` is a legal insert. `has_one` does not stop it.

The policy and feed layer takes an Account:

- `StatusPolicy` is constructed with `current_account` (`app/policies/status_policy.rb` lines 4–8). `owned?` is `author.id == current_account&.id` (lines 75–77).
- `StatusFilter#filtered?` returns false, meaning visible, when `account.id == status.account_id`, before the policy runs (`app/lib/status_filter.rb` lines 14–16).
- `Status.permitted_for` returns `all` when the viewer account is the author (`app/models/status.rb` lines 772–773).
- `Account#permitted_statuses` uses that scope and, for the author, starts from every status of the account (`app/models/account.rb` lines 513–519).
- `PersonalFeed` is constructed with an Account and loads personal statuses by `account_id` (`app/models/personal_feed.rb` lines 3–10 and 51–53).
- `AccountStatusesFeed#permission_scope` calls `permitted_statuses` (`app/models/account_statuses_feed.rb` lines 16–19).
- `Api::V1::StatusesController#set_status` loads by id and `authorize`s `:show?` (`app/controllers/api/v1/statuses_controller.rb` lines 166–174). `#set_statuses` calls `permitted_statuses_from_ids` with `current_account&.id` (lines 150–151).
- `current_account` is `current_user&.account` (`app/controllers/application_controller.rb` lines 142–146). An OAuth token's resource owner is a User (`app/controllers/api/base_controller.rb` lines 114–119). A job that only receives `account_id` has no User.

This feature does not add a unique index on `users.account_id`. That would change every local account, and it is a separate decision. Until that exists, "the account's user" is not a single principal.

Fail closed. `projection_private?(status)` is true when `statuses.external_projection` is true or a marker exists for that id. Either condition is enough. `ProjectionAccess.allow?(viewer_user_id, status_id)` is true only when a marker exists and `viewer_user_id` equals its `user_id`. A private projection is not-found unless `allow?` is true. A true column with no marker is not-found for every caller, including the account holder and the former owner. That row can only be purged. `owned?` true is not success. `viewer_user_id` nil is denial, including background jobs, serializers, and feed builders that only have an Account.

Ordinary personal posts stay on today's account rules. Those rows have the column null or false and no marker. The extra gate runs for every other status row.

| Path | What it does today | P1 gate |
| --- | --- | --- |
| `Api::V1::StatusesController#set_status`, `#show`, `#context` | `authorize :show?` with the account | `projection_private?`: 404 unless the marker's `user_id` is `current_user.id`. A true column with no marker is 404 for the account holder too, before a body is rendered. |
| `StatusesController` HTML, ActivityPub JSON, embed, history | Loads the status, then renders | Same gate. ActivityPub JSON is not rendered for a private projection, including one whose marker is gone. |
| `Status.permitted_statuses_from_ids` | `StatusFilter`, author short-circuit | The caller passes `viewer_user_id`. A projection is dropped unless it matches. Nil drops every projection. The author short-circuit does not keep it. |
| `Status.permitted_for` author branch | `all` | Excludes projection ids. This method has no User argument, so it cannot include them. |
| `Account#permitted_statuses` | Author sees the account's statuses | Excludes projection ids. A user-scoped relation is a different scope. |
| `AccountStatusesFeed` | Profile and seek use `permitted_statuses` | Other users of the same account do not see the projection on the profile or in seek. |
| `PersonalFeed` | Every personal status of the account | Ordinary personal rows stay. A projection is included only for its `user_id`. |
| `REST::StatusSerializer` | Renders whatever the controller passed | The controller does not pass a failed gate. `fedibird_external` is omitted unless that same user id was allowed. The other user does not receive the status body either. |
| `Api::V1::FavouritesController#index` | `current_account.favourites`, then the status serializer. No `show?` (`app/controllers/api/v1/favourites_controller.rb` lines 8–16 and 44–46) | Drop a projection unless `current_user.id` matches. Compact responses too. An account-level favourite row is not authorization. |
| `Api::V1::BookmarksController#index` | `current_account.bookmarks` (lines 8–16 and 44–46 of that controller) | Same filter. |
| `Api::V1::EmojiReactionsController#index` | Renders the loaded statuses (`app/controllers/api/v1/emoji_reactions_controller.rb` lines 24–33). The query is `current_account.emoji_reactions` (lines 99 and 123) | Same filter. |
| `Statuses::FavouritesController#destroy` | When the account has a favourite, assigns that status and enqueues `UnfavouriteWorker` with no `authorize` (`app/controllers/api/v1/statuses/favourites_controller.rb` lines 17–23). `authorize :show?` runs only when the row is absent (lines 24–27). Both branches render the status (line 37) | Mismatched user: 404, the favourite row stays, no worker. The response body is not rendered. |
| `Statuses::BookmarksController#destroy` | A found bookmark is assigned with no `authorize` (`app/controllers/api/v1/statuses/bookmarks_controller.rb` lines 15–22). `bookmark.destroy!` is line 25 and the status is rendered at line 27 | Mismatched user: 404, the bookmark row stays. The response body is not rendered. |
| `UnfavouriteWorker` / `UnfavouriteService` | `perform(account_id, status_id)` (`app/workers/unfavourite_worker.rb` line 6). The service destroys the account's favourite with no policy (`app/services/unfavourite_service.rb` lines 7–8) | The job carries `user_id`. A job that only has `account_id` does not destroy a projection favourite and does not render the body. |
| Emoji reaction create and destroy | `authorize :show?` in `set_status` (`app/controllers/api/v1/statuses/emoji_reactions_controller.rb` lines 30–32) | `show?` is the account policy. The user gate still applies before render or delete. |
| `BackupService` | `account.statuses` (`app/services/backup_service.rb` line 30), while `User has_many :backups` | Include a projection only when the backup's `user_id` matches. A job that only has `account_id` skips every projection. |
| Ancestors, descendants, references, search, oEmbed, outbox, admin trends | Account or public checks | Drop ids where `projection_private?` is true unless `allow?` passes. A true column with no marker is dropped for every caller. |

### Join invariants

The writer and the database both refuse a projection whose user, subscription, status account, and resource source do not agree.

`external_subscriptions` has a unique index on `(id, user_id, external_source_id)`. `external_resources` has a unique index on `(id, external_source_id)`. `status_id` references `statuses(id)`, which is already the primary key. There is no new unique index on `statuses(id, account_id)`.

The table already has indexes that start with `id, account_id`: `index_statuses_local_20190824` and `index_statuses_public_20200119` (`db/schema.rb` lines 1592–1593). Both are partial. One requires public visibility and a local or null `uri`. The other requires public visibility. Neither is unique. A partial index cannot be the target of a foreign key, and a non-partial unique index on this table is not part of this feature. Projection inserts are rare next to ordinary status writes. The check is a trigger, not an index build.

`external_status_projections` carries `account_id` and `external_source_id`, both not null, plus the columns already listed below. Foreign keys:

- `(external_subscription_id, user_id, external_source_id)` references `external_subscriptions (id, user_id, external_source_id)`
- `(external_resource_id, external_source_id)` references `external_resources (id, external_source_id)`
- `status_id` references `statuses(id)` `ON DELETE CASCADE`

The account match is an ordinary row trigger, not a constraint trigger. PostgreSQL rejects `CONSTRAINT` triggers that are `BEFORE`; a constraint trigger would have to be `AFTER ROW` and could be deferred (`CREATE TRIGGER` in the current PostgreSQL manual). This check must fail inside the marker statement, so it is not deferrable and it is not declared `CONSTRAINT`.

`external_status_projections_user_account` is `BEFORE INSERT OR UPDATE OF user_id, account_id, status_id ON external_status_projections FOR EACH ROW`. On `UPDATE`, any change to those three columns raises. On insert, and on an update that leaves them unchanged, the function reads `users.account_id` and `statuses.account_id` with `SELECT ... FOR SHARE` and raises unless both equal `NEW.account_id`. `FOR SHARE` is a row lock on that one user and that one status. It blocks a concurrent update of those `account_id` values until this transaction ends. It does not lock the `statuses` table and it does not build an index. Two users of one account may each own projections. A user of a different account, or a status whose `account_id` differs, is rejected.

Two more ordinary `BEFORE UPDATE OF account_id FOR EACH ROW` triggers keep that match from going stale. One is on `statuses` and raises when `external_projection` is true or a marker points at the row. One is on `users` and raises when any marker still has that `user_id`. Neither is a constraint trigger. `last_seen_revision` and `source_deleted` on the marker may change.

Foreign keys on the marker stay `IMMEDIATE`, the default, not `DEFERRABLE`. The writer inserts the status first, so the `status_id` foreign key and the trigger's `FOR SHARE` both see that row in the same transaction. The subscription and resource rows already exist before the marker statement. If the trigger raises, that statement fails and the writer rolls the transaction back.

The writer, in that same transaction, loads the `User`, requires `user.account_id == status.account_id`, requires the subscription and resource composite keys, then inserts the marker. A bypassed writer still fails the foreign keys or the trigger. The P1 spec reads `pg_trigger` for this name and asserts it is a non-constraint `BEFORE` row trigger.

Mismatch cases the spec inserts directly and expects a database error, with no status left behind when the writer transaction rolls back:

- `projection.user_id` differs from `subscription.user_id`
- `status.account_id` differs from `users.account_id` for that user
- `resource.external_source_id` differs from `subscription.external_source_id`

The two-users case is not a database error. Both users share `account_id`, so the trigger allows each of their own rows. The read gate is what hides user A's projection from user B.

## Projection status contract

P1 may insert a `statuses` row so `/api/v1/statuses/:id` and existing favourite/bookmark clients keep working. The row is legal only when all of the following hold:

- `external_status_projections.status_id` points at it, unique, and `user_id` is the owner.
- `statuses.external_projection` is true. The column is nullable and has no default, so existing rows stay null and ordinary inserts stay null. True is set in the same `INSERT` as the status. Null and false are not projections. The column is the privacy bit that remains if the marker row is gone. P1 adds it. A boolean with no default is a catalog change, not a rewrite of `statuses`, and it is not a second copy of `visibility`.
- `visibility` is `personal` and `searchability` is `personal`.
- `uri` is null. `Status#local?` is true when `uri` is null, which is acceptable only because `projection_private?` is stronger than `local?`.
- `text` may contain the owner's private copy of public source text. That text is not an ActivityPub `content` value.
- No `MediaAttachment`, no `PreviewCard` join, no poll, no mention rows, no hashtag rows.
- `in_reply_to_id`, `reblog_of_id`, and `quote_id` are null.
- The writer does not call `PostStatusService`, `PublishStatusService`, `ReblogService`, or `RemovalWorker`.

`statuses.external_projection` is added in the P1 migration as a nullable boolean with no default. On PostgreSQL 11 and later that is a catalog change. It is not a unique index and it does not rewrite existing rows. P1 does not add an index on this column. A partial index `WHERE external_projection` would still read the whole `statuses` table to build, and no query needs it. "Is this row private?" is the boolean on the tuple already loaded by `statuses.id`. "Which status is this marker?" is the unique index on `external_status_projections.status_id`, then that primary key. The flag stays off until the column change has committed and the specs below pass. There is no index build to wait for. Callbacks that only need the column read it on the status row, including when the marker is gone. The user gate still reads the marker, and a missing marker does not make a true column public.

`visibility = personal` still matters as defense in depth, because current fan-out already special-cases it. It is not the boundary. The audit lists paths that ignore it (`ActivityPub::DistributionWorker`, webhooks, Chewy, link crawl, delete reach).

### Fail-closed list

Any path that loads a status id must treat `projection_private?` as private, even if `visibility` was edited and even if the marker row is gone. A true column alone is enough. Before the first projection is written, these paths gain an explicit skip or refusal. The audit names the current symbols.

| Path | Required behavior |
| --- | --- |
| `Status#store_uri` | Do not set `uri` when the column is true or a marker exists. A missing marker does not allow the update. |
| `ActivityPub::TagManager#uri_for` / `#url_for` | Do not build an account status URL for a private projection. Callers serialize nothing. |
| `PublishStatusService` and `ActivityPub::DistributionWorker` | Do not enqueue. The worker also returns when the column is true or a marker exists, including `personal`, which it does not skip today. |
| `FanOutOnWriteService`, `PushUpdateWorker`, `streaming/index.js` | Publish no Redis payload for a private projection. P1 owner reads use PostgreSQL. Node does not enforce this; see the audit. |
| `trigger_create_webhooks` / `trigger_update_webhooks` | Do not enqueue when the column is true or a marker exists. Both the create callback and the update callback reload that check. |
| `search_indexable?` / `StatusesIndex` | Do not index the projection. The index scope and `delete_if` are the guard. `search_indexable?` is not, because Favourite, Bookmark, and `StatusStat` reindex without it. See Search index. |
| `FetchLinkCardService` / `LinkCrawlWorker` | Do not run. |
| `RemoveStatusService#remove_from_remote_reach` | Do not deliver Delete or Undo. |
| `BackupService` outbox export | Skip projection ids. A backup must not turn the private text into an ActivityPub Note. |
| `ReblogService`, quote, `PostStatusService` reply, `ProcessStatusReferenceService` | Refuse the projection as a target. |
| `FavouriteService` / bookmarks / emoji reactions | Local row only, and only when `ProjectionAccess` allows that `user_id`. The other user of the same account is refused. No `ActivityPub::DeliveryWorker`, no trend registration, no notification. |
| REST, HTML, oEmbed, RSS, ActivityPub show, outbox, search, trends, streaming, admin trend review, `PersonalFeed`, `AccountStatusesFeed` | Not-found unless `allow?` is true. A true column with no marker is not-found for the account holder. The other user of the same account, an unauthenticated caller, and a caller with only an Account are not-found. |
| `Status.permitted_for` / `permitted_statuses_from_ids` | The author branch and the `StatusFilter` author short-circuit exclude private projections, including a true column with no marker. A mention row must not make one visible. Projections do not create mentions. |

Ordinary `personal` posts keep today's behavior. The new condition is `projection_private?`, not a change to personal-post federation. One current behavior is called out because P1 must not inherit it: deleting a local personal status still builds follower inboxes in `StatusReachFinder` (`unsafe: true` disables the direct/limited early return) and `ActivityPub::DeleteSerializer#to` addresses Public. Projection deletion must not call that path. Changing delete reach for ordinary personal posts is a separate bugfix, not this bridge.

### Creation transaction

`Status#store_uri` and the webhook callbacks are `after_create_commit` (`app/models/status.rb` lines 673 and 678–679). They do not run if the transaction rolls back. Chewy does not use that hook. `Chewy.use_after_commit_callbacks` is false (`config/initializers/chewy.rb` line 25), so `update_index` runs on `after_save`. `Status`'s `if: :search_indexable?` (`app/models/status.rb` line 63) is evaluated then, which is before a marker inserted later in the same transaction. `search_indexable?` is `!ap_page?` today (lines 396–398). It is not the proof that a projection stays out of `StatusesIndex`.

Normative writer, one transaction, no nested transaction that commits the status early:

1. Insert the status with `uri` null, `external_projection` true, visibility `personal`, and searchability `personal`. The column is set on this `INSERT`, so `after_save` can see it. The Chewy callback may stash the id. It must not call `StatusesIndex.import!` inside this transaction.
2. Insert `external_status_projections` for that `status_id`, `user_id`, `account_id`, and `external_source_id` before commit. The subscription and resource composite foreign keys, and the user/account trigger, run here. There is no composite foreign key to `statuses`.
3. If the marker insert fails, roll the transaction back. The status row is gone. `after_create_commit` does not run. The spec also imports the rolled-back id and asserts that no Chewy document remains.
4. After commit, `store_uri` and both webhook callbacks reload the status and the marker with uncached queries. They return without writing `uri` and without enqueueing when `external_projection` is true or a marker exists. A memoized empty association, or a missing marker alone, is not evidence that the row is public. The column is on the status, so it is still visible after the marker is gone.
5. After commit, an import of that status id is allowed. It reloads through the index scope below, which does not return private projections, and Chewy deletes an id the scope misses. That import is what removes a document if one was written early. It is not run while the transaction is open.
6. No delivery or fetch worker is enqueued inside the transaction. Any worker that still receives the id reloads the status and returns before delivery or HTTP when the column is true or a marker exists. Checking only the marker is not the guard.

A crash after commit leaves a personal status with a marker and a null `uri`. That is private. It is not a success path that federates. The P1 spec rolls back between the two inserts and asserts that no status, marker, webhook job, or Chewy document remains. A second example commits both rows and asserts `uri` is null, no webhook was enqueued, and a raw get of the status id in `StatusesIndex` is empty after refresh.

Owner streaming is not part of this commit. P1 does not publish the new id to Redis. The Node process forwards whatever Ruby already published; it is not a second authorization of the projection.

### Search index

`StatusesIndex` currently scopes to `Status.include_expired.without_reblogs` (`app/chewy/statuses_index.rb` line 133). That scope includes a personal projection. These models call `update_index('statuses', ...)` without `search_indexable?`:

| Model | Line | When it fires |
| --- | --- | --- |
| `Favourite` | `app/models/favourite.rb` 16 | create and update, unconditional |
| `Bookmark` | `app/models/bookmark.rb` 16 | the `if Chewy.enabled?` is evaluated when the class loads; afterwards the callback is unconditional |
| `StatusStat` | `app/models/status_stat.rb` 21 | favourite and unfavourite update the counter, then this callback |
| `Mention` | `app/models/mention.rb` 17 | a mention row, which projections must not create |
| `StatusReference` | `app/models/status_reference.rb` 16 | indexes `target_status` |
| `PreviewCard` | `app/models/preview_card.rb` 69 | indexes joined statuses |

No other model under `app/models` calls `update_index('statuses')`. Emoji reactions have no Chewy callback of their own. If a reaction updates `StatusStat`, the `StatusStat` row above is the one that matters.

Chewy 7.6.0 reloads ids through that index scope on `import!` (`Orm#import_objects` in the installed gem). An id the scope does not return is sent as a delete, not as an index action. `CustomSidekiq` forwards ids to `import!` (`lib/chewy/strategy/custom_sidekiq.rb`). `direct_import: true` skips the reload. This app does not set it, and P1 must not pass it for `StatusesIndex`.

The scope P1 installs:

```text
index_scope Status.include_expired.without_reblogs
  .where(external_projection: [nil, false])
  .where.not(id: ExternalStatusProjection.select(:status_id))
  .reorder(nil).with_includes,
  delete_if: -> { external_projection? || ExternalStatusProjection.exists?(status_id: id) }
```

`external_projection` true keeps the id out even when the marker row has already been removed. The marker clause covers a row whose column was not set.

`delete_if` covers an object that was loaded anyway, including a `direct_import`. A full rebuild uses the scope, so it does not insert projections and does not recreate one that was deleted. A document that already exists when the marker commits is removed by the post-commit import of that id.

The spec sequence is create, refresh, favourite, refresh, bookmark, refresh, unfavourite, refresh, unbookmark, refresh. After each refresh a raw get of the status id is absent. A second example plants a document, commits the marker, runs the post-commit import, and asserts the document is gone. A third example runs a full `StatusesIndex` import of the scope and asserts the id is still absent.

The release-gate example is `drops a planted document through favourite, bookmark, stat, and a full rebuild` in `spec/services/external_bridge/projection_integrity_spec.rb`. Its name does not contain `raw document`. `-e 'raw document'` runs zero examples. `ES_ENABLED=true` is required (`config/initializers/chewy.rb`). Without a reachable cluster the example calls `skip`, and a skip is not a pass. The pass is 1 example, 0 failures, 0 pending: the raw document stays absent after create, favourite, bookmark, a `StatusStat` update, unfavourite, and a full `StatusesIndex.import!`. Point the client at a test-only cluster and a unique prefix. Do not use a production index.

```sh
RAILS_ENV=test ES_ENABLED=true ES_HOST=127.0.0.1 ES_PORT=9200 ES_PREFIX=fedibird-p1-spec \
  bundle exec rspec spec/services/external_bridge/projection_integrity_spec.rb:376 \
  --format documentation
```

If that example moves, use `-e 'drops a planted document'` instead of the line number.

### Owner-only REST extension

When the viewer is the owning user, the status JSON may include:

```text
fedibird_external:
  protocol
  canonical_url
  native_uri
  revision
  byline_name
  source_title
  interaction: local_only | native_opt_in
```

The extension is absent for every other viewer, absent from `ActivityPub::NoteSerializer`, and absent from webhook payloads. It does not contain credentials, binding ids, or ciphertext. Clients that do not understand it still see a personal status on the owner's account. Favourite and bookmark of that id stay local.

`REST::StatusSerializer` already masks `personal` as `direct` and exposes `visibility_ex`. The extension does not change that mask.

## Public reference Note

A public reference exists only after an explicit publish action. It is a different `statuses` row, with a real `uri` from `store_uri`, authored by the user's real account, distributed by the normal publish path at the visibility the user picked.

Normative body, plain text, no HTML from the external item:

```text
{optional title, one line, rejected if it contains control characters}

{protocol label}
{canonical https URL}
```

The protocol label is one of `RSS`, `Atom`, `Bluesky`, `X`, `mixi2`. The title is ordinary status text, not `post_title`, and `ap_object_type` stays null (`note`). The public post path today rejects client-supplied `post_title` and `ap_object_type`; this design does not loosen that.

The canonical URL is the item's public link, not the projection URI and not an AT URI rewritten into an ActivityPub id. Media from the external item is not attached. Mentions and hashtags parsed out of the external text are not copied. If the user types extra text, that is a different action (a normal post) and is not the reference template.

Link crawl may run on this Note, because it is a normal post. `FetchLinkCardService` will store a global `PreviewCard` for that public URL. `Trends::Links#register` already requires both the status and its original to be public. A public reference may therefore enter link trends under today's rules. The card must be built from the public HTTP response, never from projection text or from an authenticated body. A personal, unlisted, private, or direct reference does not qualify for that trend register.

### Share, reply, and boost are different activities

| User action | Record | ActivityPub effect |
| --- | --- | --- |
| Share a link | New reference Note every time (`kind = standalone_share`) | One `Create` at the chosen scope. No `Announce`. |
| Reply or quote | Auxiliary parent at a compatible scope, then a status whose `in_reply_to_id` or `quote_id` is that parent | `Create` of the parent only when that scope does not already have one, then `Create` of the reply or quote. |
| Boost | Reblog wrapper whose `reblog_of_id` is the owner's reference Note at `public`, `unlisted`, or `private` | `Announce` of that Note by the owner's account. `Create` of the Note only if it does not already exist. Direct and limited are refused: no wrapper and no `Announce`. Never `Announce` the external URL or the projection. |
| Undo boost | Discard that reblog wrapper | `Undo` of that `Announce` only. The reference Note stays. |
| Native reply or like | `external_activities` only | No ActivityPub activity. |

A share is not a boost. Calling a boost a share would drop unreblog: today's unreblog sends `ActivityPub::UndoAnnounceSerializer` and does not delete the boosted status. The boost target has to be an object this server can dereference as the owner's own Note. The private projection has no ActivityPub id. The external URL is not that Note.

Baseline behavior this uses, and does not widen:

- `StatusPolicy#reblog?` allows the owner to reblog their own non-mention-required status, including a private one (`!private? || owned?`, lines 37–39). It is false for direct and limited, because `requires_mention?` is those two visibilities (lines 71–73). It does not forbid the reblogger and the author being the same account. `ReblogService` rejects `personal` (line 41) and, when the original is `hidden?`, forces the wrapper's visibility to the original's (lines 24–29). `Status` rejects a reblog whose visibility is `direct` (line 131). A public or unlisted reference can be boosted at `public`, `unlisted`, or `private`. A private reference stays private. Direct and limited are not boost visibilities. P6 does not call another distributor to get around `reblog?` or that validation.
- One account has at most one reblog of a given status (`ReblogService` returns the existing row). A second boost click does not send a second `Announce`.
- `ActivityPub::ActivityPresenter.from_status` sets type `Announce` for a reblog (line 10). The object is the original's URI, except when the booster is the author, the original is a local private status, and the Note is inlined (lines 18–20). A public or unlisted self-boost does not inline a second copy of the body.
- `FeedManager#add_to_feed` skips a reblog when the original is already within `REBLOG_FALLOFF` of the top of that local feed (lines 533–539). That dedup is local. It is not a promise about remote servers or relays.
- `ActivityPub::DistributionWorker#relay!` runs for public visibility. A public `Create` and a later public `Announce` are two activities. They are not two `Create`s. Followers who already stored the Note receive an Announce of its URI.

If a public, unlisted, or private reference Note already exists, a boost distributes only the `Announce`. A direct or limited Note is not that target. The original `Create` is not sent again. If none of those three exists, and the requested visibility is one of them, the confirm step states the audience and that both a link post and a boost will be published. The `Create` is distributed once, then the `Announce`. Remote software may still show both. That is the same shape as publishing a post and boosting it. P6 records what a Mastodon follower and a relay actually display before the flag is turned on. This design does not relabel the boost as a share to hide that second activity.

Undo of the boost removes the wrapper and sends Undo of the Announce. Delete of the reference Note is a separate action, uses the normal Delete path for that Note, and also removes its reblogs through `RemoveStatusService#remove_reblogs`. The projection is neither the Announce object nor the Delete object.

### Auxiliary parent scope

An auxiliary parent is not unique for the whole `(user, resource)` pair. The unique key is `(user_id, external_resource_id, distribution_scope)`.

`distribution_scope` is `public`, `unlisted`, `private`, or `direct:` / `limited:` plus the sorted recipient account ids. `mutual` is not a parent scope. Direct and limited parents exist for reply and quote. They are not boost targets. A boost of either scope is refused before a wrapper or an `Announce` is created.

Reuse:

- A child at scope S may use an existing parent at S.
- A child at `unlisted` or `private` may use an existing `public` parent. A `private` child may use an existing `unlisted` parent. Pointing a narrower reply at a broader parent does not publish the parent to anyone new.
- Direct and limited reuse only the exact recipient set.
- A wider child must not reuse a narrower parent and must not change that parent's visibility. The confirm step creates a new parent at the wider scope and names that audience. Example: a followers-only parent already exists, and the user asks for a public reply. The public reply gets a new public parent. The followers-only parent stays followers-only.

Parent visibility, recipient set, and circle are frozen. `UpdateStatusService` refuses those changes on an auxiliary parent. A standalone share is not selected as a parent and may be edited under the normal status rules.

Creation takes one transaction and a lock on the unique key. A concurrent insert that loses the unique index reloads the winner and does not distribute a second `Create`. Both requests must include `confirm_parent_scope` equal to the scope that would be created. Without it, the response is `parent_confirmation_required` and nothing is inserted.

Deleting the parent deletes the reference row with the status. The bridge does not retarget existing replies or quotes onto a later parent. The next reply at that scope confirms a new parent. Orphaned replies follow the existing `in_reply_to_id` delete behavior and are not republished.

The reply's ActivityPub `inReplyTo` is the chosen parent's local URI. It is not the external URL, not the AT URI, and not the projection. Remote servers may still notice the URL inside the text. Whether Bridgy Fed or another bridge will fetch that URL and post back is **not established**. P6 does not ship until an experiment records the result for both a `Create` and an `Announce` of the reference Note. Mitigations that are in this design anyway: the object id is the local status URI, the actor is the Fedibird user, and nothing sets the external author as `attributedTo`.

`Formatter#format_bridgy_fed` rewrites spoiler text for display of bridged content this instance already ingested. It is not a license to republish external bodies, and this bridge does not call it to manufacture posts.

## Identity and revisions

### RSS and Atom

Source key: the canonical feed URL.

Normalization, applied only after every redirect hop has passed `Request` / `PrivateAddressCheck`:

- lowercase scheme and host
- drop the fragment
- drop the default port
- drop a trailing slash only when the path is empty
- preserve query order
- reject userinfo. A username or password in the URL is not stored. The subscribe attempt is rejected. P1 through P3 have no authenticated-feed model to put it in.

If the query contains `token`, `key`, `sig`, `signature`, or `access_token`, the attempt is rejected the same way. No shared row is inserted to remember that the URL was tried.

Item key, first match:

1. RSS `guid` or Atom `id`, trimmed and non-empty, scoped to the source key.
2. Else the entry link URL, normalized the same way, scoped to the source key.

Entries with neither are skipped. A content hash is not an identity. The same guid on two feeds is two resources. A byline string is display text, not an actor id. The feed's `external_actors` key is the source key.

### AT Protocol

Resource key: the AT URI `at://<did>/<collection>/<rkey>`, parsed as an AT URI. This document does not treat a regex as a parser. The DID is case-sensitive. The handle is not the key.

Revision: the CID. A new CID at the same AT URI updates the shared row's revision and digest. It does not insert a second resource and does not emit an ActivityPub `Update`. Each projection stores `last_seen_revision` so the owner can see that the source changed. The public reference Note is left unchanged unless the user explicitly publishes again, which creates a new standalone share rather than editing the old one in place.

A missing public record sets `source_deleted_at` on the shared row. That is a public observation. It does not delete other users' projections. Each projection hides or keeps the last public copy under the owner's local retention choice. P1's choice is: keep the projection text, mark it source-deleted, and do not refetch it into the shared body.

Native like and repost records have their own AT URIs and CIDs. Those are columns on the owner's `external_activities` row, not the subject resource key.

A public record fetched with no user token may be an `external_resources` row. A follower-only record, a record fetched with `Authorization`, or a non-2xx response is not. P1 through P3 reject that fetch. They do not create a shared source or resource, and they do not write a private blob as a stand-in. The owner's own native object can still be named on an `external_activities` row when the user performs a native action, without copying an authenticated body into `external_resources`.

### URL canonicalization limits

Redirects can collapse two user-entered URLs onto one source. That merge is allowed only after every hop is a public 2xx response. Each user still keeps their own subscription row. A query that contains `token`, `key`, `sig`, `signature`, or `access_token` is rejected. Those parameters are not stripped into a shared key, and the attempt writes no source, resource, or cache entry.

## Cache keys

Public material, no credential on the request and a completed 2xx response:

```text
v1:external_public/<protocol>/<sha256(canonical_key)>/<revision>
```

There is no private cache key in this design. A later private-resource model must not reuse `v1:external_public`, and it must not store an authenticated body under a key that another user can read. Personal DeepL's `user` / `credential` / `binding` partition is the pattern that later model has to follow. It is not implemented by a column on `external_resources`.

The digest input is the canonical key after secrets are removed. The key does not contain a token or a raw URL that still has userinfo or a token query. A shared entry stores no `user_id`. A rejected or failed fetch writes no cache entry.

Caps, required before P1 writes a body: at most 1 MiB of stored text, a recorded `truncated` flag, and a response byte limit on the HTTP client. XML parsers for RSS must disable network entity resolution. The HTTP client is the existing `Request` class, which rejects private addresses, not a new open client.

Public fetch jobs carry `subscription_id` or `resource_id` only. They do not carry a credential id. A later authenticated job, if a private model exists, follows the vault rule: `owner_user_id`, `credential_id`, `provider`, `purpose`, and `credential_type`, and never a URL and a secret together.

## Data model

Names are the contract for later migrations. P0 does not add them. Types are the intended PostgreSQL shape.

Shared tables have **no** `user_id`. Owner tables are `NOT NULL user_id` with `ON DELETE CASCADE` to `users`. `external_status_projections.user_id` is the exception: `ON DELETE RESTRICT`, so deleting a user cannot drop the marker and leave the status.

### `external_sources`

| Column | Constraint |
| --- | --- |
| `id` | primary key |
| `protocol` | `rss`, `atom`, `atproto` in the phases below. `x` and `mixi2` are reserved and unused until a terms review |
| `canonical_key` | not null |
| `etag`, `last_modified`, `fetched_at` | nullable, and only from a completed public 2xx response |
| `title`, `site_url` | nullable public metadata |

Unique `(protocol, canonical_key)`. No subscriber count, no `fetch_class`, and no HTTP status from an authenticated or failed response. A 401, 403, redirect to a private address, or token-bearing URL does not insert or update this row. If a previously public source later answers 401, the shared ETag is left as it was and the owner's subscription goes to `error`. The 401 body is discarded.

### `external_actors`

| Column | Constraint |
| --- | --- |
| `id` | primary key |
| `protocol` | not null |
| `native_id` | DID, or the source key for an RSS feed |
| `handle`, `display_name`, `profile_url` | nullable, public, mutable |
| `avatar_remote_url` | nullable. P1 does not download it into `media_attachments` |

Unique `(protocol, native_id)`.

### `external_resources`

| Column | Constraint |
| --- | --- |
| `id` | primary key |
| `external_source_id` | not null, FK cascade from source only if an operator removes a source. Not deleted when a user leaves |
| `external_actor_id` | nullable FK |
| `protocol` | not null |
| `canonical_key` | not null |
| `revision` | CID or content digest of the public body. Not an identity |
| `canonical_url` | nullable public link |
| `title`, `body`, `body_digest` | text from a public 2xx fetch only. Never null-as-a-placeholder for an authenticated body |
| `published_at`, `source_deleted_at`, `truncated` | |
| `fetched_at` | |

Unique `(protocol, canonical_key)`. Index `(external_source_id, published_at)`.

### Authenticated resources are not this schema

`external_private_blobs` is not part of the model. A user-scoped body that still points at a globally unique `(protocol, canonical_key)` would publish existence, and an ETag on `external_sources` would publish authorization-dependent validators. P1 through P3 reject those fetches instead.

A later design, not this one, has to give the private source and the private resource a primary key that includes `user_id`, `credential_id`, and `binding_id`, with no foreign key to a global resource id, and with ETag and error metadata only on the owner row. Projections of those resources would reference that owner-scoped id. Until that design is reviewed, no projection has an `external_resource_id` produced by a private fetch.

### `external_subscriptions`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_source_id` | not null. The source must already be a public row, or be created by this user's public 2xx fetch in the same transaction |
| `state` | `active`, `paused`, `error` |
| `last_error_code` | nullable class or provider code. No response body and no token |

Unique `(user_id, external_source_id)`. No `credential_id`. A subscribe request that needs a credential returns `authenticated_source_rejected` and inserts neither a subscription nor a source.

### `external_status_projections`

| Column | Constraint |
| --- | --- |
| `user_id` | not null. `ON DELETE RESTRICT`. The read principal. Deleting the user does not delete this row |
| `account_id` | not null. Equals `statuses.account_id` and `users.account_id` for `user_id` |
| `external_source_id` | not null. Equals the subscription's source and the resource's source |
| `external_subscription_id` | not null |
| `external_resource_id` | not null |
| `status_id` | not null, unique, FK to `statuses(id)` `ON DELETE CASCADE` |
| `last_seen_revision` | nullable |
| `source_deleted` | boolean, default false |

Unique `(user_id, external_resource_id)`.

`user_id` does not cascade. `DeleteAccountService#purge_content!` calls `purge_user!` before `purge_statuses!` (`app/services/delete_account_service.rb` lines 144–146). `purge_user!` destroys the user when the email is not kept (lines 135–139). A cascade from that destroy would delete the marker and leave the status, and the later removal would treat it as an ordinary personal post. `ON DELETE RESTRICT` makes `User#destroy` and `DELETE FROM users` fail while any marker for that user remains.

`AccountAssociations` declares `has_one :user, dependent: :destroy` (`app/models/concerns/account_associations.rb` line 8) before `has_many :statuses, dependent: :destroy` (line 15). Destroying the account therefore destroys the user before the statuses. The same `RESTRICT` aborts that destroy while a marker remains. The deletion service removes that user's projection statuses first, in the same transaction, through the non-federating path.

`status_id` cascades only on a physical `DELETE` of the status row. `Status` includes `Discard::Model` with `discard_column = :deleted_at` (`app/models/status.rb` lines 44 and 57). `discard` updates `deleted_at`. It does not delete the row, so it does not cascade the marker. `RemoveStatusService#call` discards first (`app/services/remove_status_service.rb` line 24), may call `remove_from_remote_reach` (line 40), and calls `destroy!` only when `permanently?` (lines 61 and 226–228). A discarded projection still holds its marker, so a later `DELETE FROM users` fails on `RESTRICT`, and the remote-reach call can already have run. Discard is not a successful projection delete.

The purge is one database transaction. It sets `fedibird.projection_status_delete` to `on` for that transaction only (`SET LOCAL`), then `DELETE`s the status rows. The foreign key cascades the markers. The transaction then continues to the user delete when that was the caller's goal. If any statement raises, the transaction rolls back: the statuses, the markers, and the user row are unchanged. Retry starts at `SET LOCAL` again. A committed state where `deleted_at` is set and the marker remains is not success.

An ordinary `BEFORE DELETE FOR EACH ROW` trigger on `external_status_projections` rejects a marker delete while `statuses.id` still exists, unless that local setting is `on`. It is not a constraint trigger. `BEFORE` is valid for an ordinary trigger; the `CONSTRAINT` form is what PostgreSQL limits to `AFTER ROW`. The purge sets the local setting and then deletes the status. A direct `DELETE` of the marker, and a user delete, do not set it. The cascade during the status `DELETE` still sees the status row, which is why the setting is required and why `EXISTS (status)` alone cannot allow the cascade. If the marker is nevertheless removed and `external_projection` is still true, every read returns not-found, including for the former owner, and no delivery, webhook, `store_uri`, or index import treats the row as a normal personal status. Repair is the same physical `DELETE`. It does not clear the column and leave the text in place.

### `external_identities`

The connection metadata model required by `docs/external_services.md` when a provider needs host, subject, handle, scopes, or expiry. Not a JSON column on `user_external_credentials`.

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `provider` | registry key, for example `bluesky` |
| `subject` | DID. Bound from the token `sub` after the checks in the OAuth section. Not a handle |
| `issuer` | authorization-server origin that issued the session. Not a secret |
| `resource_origin` | PDS origin the session was bound to. Not a secret |
| `handle`, `display_name` | nullable, re-verified. Not an identity key |
| `credential_id` | nullable FK. The vault holds the refresh token and the session DPoP key. It does not hold the instance confidential-client key |
| `granted_scopes` | scopes the token response returned. Not a copy of the token |
| `disconnected_at` | nullable |
| `terms_state` | `unreviewed`, `approved`, `rejected`. X and mixi2 stay `unreviewed` |

Unique `(user_id, provider, subject)`.

`PostingIdentity::KNOWN_KINDS` already names `bluesky`, and `ENABLED_KINDS` is only `local`. This bridge does not enable that kind. A native identity is not a Fedibird posting sender. The ActivityPub actor remains the local account.

Vault classification used by the P2 Bluesky identity connection:

```text
provider        = bluesky
purpose         = identity
credential_type = oauth_session
```

The payload is the refresh token and the DPoP key material for that session. An app password is not this classification. The browser cannot choose these values. There is no `POST /settings/external_services/:provider`. The confidential client's signing key is an instance secret, separate from `USER_EXTERNAL_CREDENTIAL_KEYS`, because it is not owned by one user.

### `external_activities`

One row is one native object the owner created, or the in-flight attempt to create or delete it. Unlike and unrepost are not separate rows. They are transitions on the row that remembers the native record.

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_identity_id` | not null |
| `external_resource_id` | nullable. Set only for a public resource. A native action on the owner's own object may leave this null and store `subject_uri` instead |
| `external_status_projection_id` | nullable |
| `verb` | `like`, `repost`, or `reply` |
| `desired` | `active` or `inactive` |
| `remote_state` | `absent`, `pending_create`, `present`, `pending_delete`, or `unknown` |
| `generation` | integer. The latest accepted command's generation. Not an idempotency key |
| `subject_uri` | AT URI of the record being liked, reposted, or replied to |
| `subject_cid` | nullable CID observed when the attempt started |
| `native_activity_uri` | AT URI of the like, repost, or reply record once known |
| `native_activity_cid` | nullable CID of that record |
| `attempt_count`, `last_error_code` | no token and no raw body |
| `local_favourite_id`, `local_status_id` | nullable. Local rows are not evidence of remote success |

This row does not store the client's idempotency key. A single column would be overwritten on unlike, and a later retry of the like key would look new. Per-intent keys live on `external_activity_commands`.

Unique `(user_id, external_identity_id, subject_uri, verb)` where `verb` is `like` or `repost`. That row stays through unlike and a later like. It is not deleted to make room for a second like row. Replies are outside that index; each reply has its own command and its own `native_activity_uri`.

`like → unlike → like` uses that one like row:

1. `desired = active`, `remote_state = pending_create`. `createRecord` on the resolved PDS. On success, store `native_activity_uri` and `native_activity_cid`, set `remote_state = present`.
2. Unlike sets `desired = inactive` and `remote_state = pending_delete`, then `deleteRecord` of **that** URI and rkey. It does not invent a second like URI. On success, `remote_state = absent`. The old URI stays in `native_activity_uri` until the next successful create replaces it, so a retry still knows what to delete.
3. A later like creates a new record and a new rkey. It does not reuse a rkey whose delete is unconfirmed.

Lost response: if the HTTP call was sent and the response was lost or timed out, set `remote_state = unknown`. Do not set `present` and do not send another `createRecord` just because a command key matches. Reconcile first with `getRecord` or `listRecords` for this DID, collection, and subject. If a record exists, adopt its URI and CID. If it does not, the next attempt may create one. A retry of the latest command returns that command and re-enters that reconcile. It is not proof the provider committed nothing. A retry of an older command does not.

401 or a revoked credential: stop. Do not refresh by sending the token to a different host. If the write might have left the process, `remote_state` stays `unknown` until a later authorized reconcile. Revocation does not claim the remote like is gone.

Concurrent clicks: the unique subject index plus `generation` makes the second request either observe the current generation or lose the update. The loser does not start a second PDS write.

Local favourite and the native like commit independently. A remote failure does not delete the local favourite. A local failure does not invent `remote_state = present`. There is no automatic remote rollback. Compensation is a later delete of the stored `native_activity_uri` after reconcile shows the record exists.

### `external_activity_commands`

One immutable row per client intent. Like, unlike, and a later like are three rows. The activity row's `generation` points at the latest one.

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_identity_id` | not null |
| `external_activity_id` | not null once the activity row exists |
| `idempotency_key` | not null, never updated |
| `verb` | `like`, `repost`, or `reply` |
| `desired` | `active` or `inactive`. The intent of this command, not the current activity state |
| `generation` | integer assigned when this command becomes latest |
| `expected_generation` | the generation the client sent. `0` when the activity row does not exist yet |
| `subject_uri` | AT URI this command applies to |

Unique `(user_id, external_identity_id, idempotency_key)`. Two users may send the same string.

Acceptance:

1. The key already exists and it is the latest command. Return it and re-enter reconcile for that command. Do not start a second transition. If the key exists and its `generation` is older, do not change `desired`, do not call the PDS, and respond `superseded` with the current activity state.
2. The key is new and `expected_generation` equals the activity's current `generation`. Insert the command, increment `generation`, and perform that transition.
3. The key is new and `expected_generation` does not match. Respond `stale_activity_command`. No PDS write and no change to `desired`.

A replay of the original like after unlike is refused by both checks: the old key hits rule 1, and a new key that still carries the like's `expected_generation` hits rule 3. Neither creates a new like record. The next like the user actually requests sends the current `generation` and a new key, then uses a new rkey as above.

### `inbound_interactions`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_identity_id` | not null |
| `protocol` | not null |
| `native_activity_id` | not null |
| `native_actor_id`, `native_object_id`, `in_reply_to_native_id` | not null where the protocol has them |
| `kind` | `reply`, `like`, `repost` |
| `summary` | owner-scoped text. Not copied into `external_resources` |
| `observed_at` | |

Unique `(user_id, protocol, native_activity_id)`.

### `external_actor_mutes`

Unique `(user_id, external_actor_id)`. A mute hides that actor's projections from the owner. It does not create an `Account` block and it is not delivered over ActivityPub.

### `publication_groups` and `publication_group_members`

P3's verbs are like, repost, and reply. The capability list has no `create_post`. A like, repost, or reply record is not a crosspost member, and P5 does not create a native post.

A group exists only when the user explicitly adds members. A local member is a `local_status_id` the user selected. A native member is an AT URI the user submitted, after a read of that record shows its repo DID equals `external_identities.subject`. The read uses the resolved PDS or a configured public AppView. It does not send the user token to a URL the user typed. Text, canonical URL, and CID similarity do not insert a member. Unique member identity inside the group. Owner-only reaction counts sum snapshots for those linked records only. Native posting can be a later phase. It is not P3 or P5.

### `external_ap_references`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_resource_id` | not null |
| `status_id` | not null, unique, the reference Note |
| `kind` | `auxiliary_parent` or `standalone_share` |
| `distribution_scope` | not null for `auxiliary_parent`. The frozen scope string |

Partial unique index on `(user_id, external_resource_id, distribution_scope)` where `kind = auxiliary_parent`. Standalone shares are not unique. A boost does not insert its own reference kind. It reblogs a public, unlisted, or private reference Note. A Note created so that a boost has a target is an `auxiliary_parent` at one of those three scopes, so a later reply can reuse it under the scope rules. A direct or limited parent is never selected as a boost target. Deleting the Note deletes the reference row. It does not delete the projection.

### Reaction snapshots

`external_reaction_snapshots` is owner-scoped: `(user_id, external_resource_id, platform, kind, count, fetched_at)`. Platforms stay in separate rows. Counts are not added into `status_stat.favourites_count` or `reblogs_count`, because those columns feed status trends when a status is public. The public reference Note's counters count Fediverse interactions only.

## Provider and capability contract

Providers are static objects on `ExternalServices::Registry`, the same rule as DeepL. P0 does not register a provider.

A later provider object exposes the existing presentation methods (`key`, `display_name`, `connections_for`, `catalog_entry_for`, `manage_path`) plus a capability list the server owns:

```text
read_public_source
like
unlike
repost
unrepost
reply
read_inbound
```

Capabilities are false until the provider implements them. The client cannot turn a capability on. X and mixi2 additionally require `terms_state = approved` on the identity, set only by a reviewed provider class, not by a request parameter.

Public RSS fetches use `Request` with no vault access. They still have a per-host rate limit and a response size limit.

### AT Protocol OAuth and write routing

This is the P2 session contract and the P3 write contract. P2 does not perform like, repost, or reply writes. P3 does not send those writes to a fixed Bluesky host.

The authoritative profile is the AT Protocol OAuth specification. In that profile the PDS is the resource server. The authorization server is often the same origin and is sometimes a separate entryway. Bluesky's own directory lists `https://bsky.social` as an entryway and per-user PDS hosts under `bsky.network`, with public reads available at `https://public.api.bsky.app`. Those names are examples of the split. They are not the write endpoint for every account.

Two different inputs:

- **A URL the user types is not a place a stored token is sent.** The vault still forbids a credential plus an arbitrary URL. After a token exists, request targets come only from resolution and metadata.
- **Discovery is allowed to start from a handle, a DID, or a hosting hostname,** because the OAuth profile permits a hostname start when the user does not have a working handle. A hostname start does not bind an account. The session is stored only after the checks below succeed.

P2 is implemented by the services under `app/services/external_bridge/atproto/` and documented in `docs/atproto_oauth.md`. The flag stays off. P2 minimum, in order:

1. The user supplies a handle, a DID, or a hosting hostname. They do not supply a token, and they do not supply the URL that will receive the token.
2. A handle resolves to a DID and the DID document claims that handle. Both directions are required. A DID is resolved directly. All handle methods and DID methods the profile requires are in scope; an account that this server cannot resolve is `discovery_rejected`, not sent to `bsky.social`.
3. The DID document's `#atproto_pds` service is the PDS. The client fetches `https://<pds-origin>/.well-known/oauth-protected-resource` and reads its single `authorization_servers` entry, then `/.well-known/oauth-authorization-server` on that origin. `issuer` must match that origin. Metadata must advertise the profile this client needs: `atproto`, PAR, PKCE `S256`, and DPoP. A redirect or a non-200 metadata response fails discovery.
4. Every resolution and metadata URL is `https`, has no userinfo, and is checked with `Request` / `PrivateAddressCheck` on every hop, including redirects. A failure here aborts before any token request.
5. Fedibird acts as a confidential client. `client_id` is a public metadata URL. The client signing key is an instance key. The authorization uses PAR, PKCE, and DPoP. P2 requests only the `atproto` scope. A server that advertises one `repo:` scope, or only `transition:generic`, does not cause this client to request like, repost, reply, or `transition:generic`. Those repository scopes are a later explicit upgrade, and only for scopes that server lists. `transition:chat.bsky` and `transition:email` are not requested.
6. The token response's `sub` is a DID. The client resolves that DID again, reads the PDS, confirms the PDS metadata names the authorization server that just issued the token, and confirms `issuer`. On mismatch the tokens are discarded and nothing is stored.
7. The vault row is `oauth_session` for this user. `external_identities` stores `subject`, `issuer`, `resource_origin`, and `granted_scopes`. Handles are display data.

Refresh tokens are single-use. The in-flight marker is committed before the refresh token is sent, and a later call does not send that token again. Refresh goes to the bound `issuer` only. The token response `sub` must be the DID already stored for that identity. A temporary DID, PDS, or metadata outage before that send leaves the session connected and does not revoke it. If a later DID resolution shows a different authorization server, or the token endpoint no longer matches, the refresh token is not sent there and the user signs in again. The confidential client keeps the signing key that attested PAR for the whole session. Local disconnect is committed before a remote revocation request, including when the stored payload cannot be sent. If a refresh response arrives after that commit, the new refresh token is sent to the bound revocation endpoint and is not stored. Expired open OAuth attempts are deleted in bounded batches. Consumed attempts stay until the rate window and a short callback grace have both elapsed, so the per-user cap still counts them.

P3 write, immediately before `com.atproto.repo.createRecord` or `deleteRecord`:

1. Resolve the DID document again.
2. The write origin is the current `#atproto_pds` endpoint, not `bsky.social`, not `public.api.bsky.app`, and not a hostname the user typed earlier if that hostname was only the entryway.
3. If that origin differs from `resource_origin`, do not send the current access token to the old host or the new host. Refresh only when the new PDS's protected-resource metadata still names the bound `issuer`. If the issuer changed, stop with `reauthentication_required`.
4. The DPoP proof's `htu` is the PDS request URL. A 401 stops the attempt. It does not retry against another host.
5. Public reads of public records, including P1-style shared cache fills, may use a server-configured public AppView and must not attach the user token. A follower-only read is `authenticated_source_rejected` until the private resource model exists.

App passwords are out of scope for P2 and P3. They have no `issuer`, no DPoP binding, and no `sub` check against a DID document. Support is any account whose handle or DID, PDS, and authorization server pass these checks. It is not "Bluesky-hosted accounts on one session host." Accounts that fail discovery are unsupported for that attempt, with `discovery_rejected`.

Sudo matches the external-services pages: mutation routes require a recent challenge, secrets never enter the challenge, the flash, or the redirect. There is no credential REST API.

## Consent and ordinary API clients

| Action | Default for an ordinary Mastodon client | What the Fedibird UI can add |
| --- | --- | --- |
| Read a projection | Owner-only GET of the status id | External byline from `fedibird_external` |
| Favourite / unfavourite | Local favourite only | Separate control: also like on the connected identity |
| Bookmark | Local bookmark only. Bookmarks are already local | None |
| Reply | **422**. A normal reply would be a real status pointing at the projection | Two controls: "Reply on Fediverse" (reference flow) and "Reply on Bluesky" (native) |
| Boost | **422** on the projection. `ReblogService` already rejects `personal`, and the marker is a second refusal. Direct and limited reference Notes are also refused | "Share" is one `Create`. "Boost" is `Announce` of the owner's public, unlisted, or private reference Note, after confirm if that Note must be created |
| Quote | **422** | Quote the auxiliary parent only after the user confirms that parent will be published |
| Emoji reaction | **422** on a projection. Today's service notifies a local author or delivers to a remote inbox | None in the first slices |

The ordinary client keeps a predictable local favourite and bookmark. It does not gain a silent remote side effect. Routing is opt-in per action, stored on the activity row (`local_only` versus `native`), not inferred from the status visibility.

The Fedibird composer labels the two reply buttons with the destination. The native button is disabled when there is no identity, the capability is off, or the credential is revoked. The disabled state is not reported as success.

## Operation matrix

Local favourite and bookmark rows follow today's owner-only `show?` once the projection is a personal status. The columns below are the additional contract.

### Read / import

| | |
| --- | --- |
| Local effect | Subscription row. For each accepted item, one projection and one personal status for this user only. |
| Native side | None. Public AT records may be read from a public AppView without the user token. Anything that requires a token is rejected. |
| ActivityPub | None. |
| Consent | The user adds the source. Public RSS needs no remote account. |
| Idempotency | Unique `(user, source)` and `(user, resource)`. A refetch updates `last_seen_revision` in place. |
| Failure | A failed or non-public fetch inserts no shared source, resource, actor, or cache entry. An existing public subscription can move to `error` without updating the shared ETag from that response. Partial item failure skips that item. Status and marker commit in one transaction, or neither does. |
| No identity | Public RSS and other public fetches succeed. Authenticated sources return `authenticated_source_rejected`. |
| Revoked credential | Does not apply to public fetch. Existing public projections stay. No private blob is served, because none is stored. |

### Favourite / unfavourite

| | |
| --- | --- |
| Local effect | `Favourite` on the projection status for the owner. Unfavourite destroys that row. `status_stat.favourites_count` changes only on that status. |
| Native side | None unless the user opted in. Opt-in uses the like row's `desired` / `remote_state` transitions and `createRecord` or `deleteRecord` on the resolved PDS. |
| ActivityPub | None. The author account is the owner's own account, so today's `FavouriteService` would notify the owner. The projection path must not fan that notification out as if a third party acted, and must not call `Trends.statuses.register`. |
| Consent | Local favourite needs no extra consent. Native like needs a connected capability and an explicit opt-in. |
| Idempotency | Local `find_or_create` by `(account, status)`. Native keys are unique per `(user, identity, idempotency_key)` on the command row. A retry of the latest command reconciles before another create. A retry of an older command is `superseded` or `stale_activity_command` and does not create. One like row per subject. |
| Failure | `remote_state` is `unknown` or stays pending. It is not `present` without a stored `native_activity_uri` from a response or a reconcile. The local favourite is unchanged if the user asked for both. A native-only request that never reaches `present` creates no local favourite. |
| No identity / revoked | Local favourite still works. Native opt-in returns `external_identity_required` or `credential_revoked`. A write that may have left the server stays `unknown` until reconcile. |

### Bookmark

| | |
| --- | --- |
| Local effect | Bookmark row. Already not federated. |
| Native / ActivityPub | None. There is no remote bookmark capability in this design. |
| Consent | Local only. |
| Failure | Same as today's bookmark create. |

### Reply

| | |
| --- | --- |
| Local effect | Fediverse reply: auxiliary parent plus a new status by the user, `in_reply_to` the parent, not the projection. Native reply: an `external_activities` row with `verb = reply`, optional local note only if the user also composed a Fediverse reply. |
| Native side | Native reply posts as the linked identity. The target id is the native object id, not the projection id. |
| ActivityPub | Parent `Create` plus reply `Create`, at the visibilities the user confirmed. No activity for a native-only reply. |
| Consent | Required before the parent is created. Required again for the native post if it is a separate button. |
| Idempotency | Auxiliary parent unique on `(user, resource, distribution_scope)`. A lost race reloads the winner. Native reply retries of the latest command reconcile `native_activity_uri` before another `createRecord`. An older command does not post again. |
| Failure | If the parent is created and the reply save fails, the parent remains; the confirm step already named its audience. A wider reply does not widen an older parent. Native failure leaves `remote_state` unknown or absent and does not delete a Fediverse reply that already succeeded. |
| No identity / revoked | Fediverse reply can still be offered. Native reply is refused before any local "sent" state. |

### Boost / repost / undo

| | |
| --- | --- |
| Local effect | Fediverse **share** creates a standalone reference Note and stops. Fediverse **boost** creates a reblog of the owner's reference Note at `public`, `unlisted`, or `private`, creating that Note only when the confirm step said it would. Direct and limited are refused with no wrapper. Neither mode reblogs the projection. Native repost uses the repost row on `external_activities`. |
| Native side | `createRecord` or `deleteRecord` of the repost record on the resolved PDS. Undo deletes the stored `native_activity_uri`. |
| ActivityPub | Share: one `Create`, no `Announce`. Boost: `Announce` of a public, unlisted, or private reference Note. `Create` of that Note only on first publication at that scope. Direct and limited produce no `Announce`. Undo boost: `Undo` of the `Announce` only. Never `Announce` the external URL or the projection. A native unrepost does not emit ActivityPub `Undo`. |
| Consent | Share confirms the Note's audience. Boost confirms the Announce, and also confirms the Note's audience when the Note does not exist yet. Native repost is a separate opt-in. |
| Idempotency | A second Fediverse boost finds the existing reblog wrapper and does not send another `Announce`. A second share is a new Note only after another confirm. A direct or limited boost request does not create a parent to boost. Native repost follows the same command and reconcile rules as like. |
| Failure | If Note creation succeeds and the wrapper save fails, the Note remains and the UI does not claim the boost succeeded. Native `unknown` is not shown as a completed repost. |
| No identity / revoked | Fediverse share and boost can proceed. Native repost is refused, or left `unknown` if a write may already have been sent. |

### Quote

| | |
| --- | --- |
| Local effect | Quote status whose `quote_id` is the auxiliary parent. |
| Native side | None unless a later provider capability exists. AT quote-post is not in the first native slice; do not map it onto reply silently. |
| ActivityPub | `Create` with the existing quote URI fields pointing at the parent's local URI. |
| Consent | Same scope confirm as reply. A quote does not widen an existing narrower parent. |
| Failure | Do not quote the projection if parent creation fails. |

### Native inbound

| | |
| --- | --- |
| Local effect | `inbound_interactions` rows. Optional owner-only inbox API. |
| Native side | Read using the identity, or filter a public firehose down to the owner's subject. Replies the user sends back are outbound activities. |
| ActivityPub | None. No `Notification`, no remote `Account`, no `Like` activity, no distribution. |
| Consent | The user turns inbound sync on for that identity. |
| Idempotency | Unique `(user, protocol, native_activity_id)`. |
| Failure | Cursor or watermark stays on the last success. Partial page failure does not drop already stored rows and does not mark the gap as complete. |
| No identity / revoked | Sync stops. Stored rows remain until disconnect, which deletes inbound payloads for that identity. Public RSS projections are not deleted by an identity disconnect. |

### AP reference creation

| | |
| --- | --- |
| Local effect | Reference Note plus `external_ap_references`. |
| Native side | None. |
| ActivityPub | Normal `Create` / later `Delete` of that Note only. |
| Consent | The publish confirm, including audience. |
| Idempotency | One auxiliary parent per `(user, resource, distribution_scope)`. A repeated reply at that scope reuses it. A repeated share creates a new standalone Note only when confirmed again. |
| Failure | A failed `Create` delivery follows today's distribution retry for that reference Note only. The private projection is unchanged. A failed `Announce` does not send a second `Create`. |
| Visibility change | Auxiliary parent scope is frozen. A different audience creates a different parent after confirm. Standalone shares may be edited under normal status rules and are not parents. Editing a projection is refused. Promoting a projection by changing `visibility` is refused: the federated object is a new reference built from the template. |

## Deletion, disconnect, and moderation

Projection purge, used by the one-projection, user, and account cases below, is a physical `DELETE FROM statuses` for the chosen ids. The statement is SQL `DELETE`, not `Status#destroy!`, so status, favourite, and bookmark callbacks do not run. It does not call `Status#discard`, `RemoveStatusService`, `BatchedRemoveStatusService`, or `RemovalWorker`. `BatchedRemoveStatusService` does use `delete_all` (`app/services/batched_remove_status_service.rb` line 34), but `purge_statuses!` runs only after `purge_user!`, and that service does not set `fedibird.projection_status_delete`. Projections are removed before either of those steps.

The purge transaction:

1. `SET LOCAL fedibird.projection_status_delete = 'on'`.
2. `DELETE` the selected status rows. Cascaded foreign keys remove the markers, favourites, bookmarks, and emoji reactions (`db/schema.rb` lines 1911, 1930, and 1937). No `DeliveryWorker`, no Redis payload, no webhook.
3. On an exception, roll back. A purge that started with both rows still has both, `uri` is still null, and the owner can still read. A repair that started with a true column and no marker still has that status and still has no marker. Retry is the same transaction. Do not commit a discard and retry the user delete later.

- **Delete one projection.** Purge that status id. The shared resource remains. Deleting the marker first is rejected by the `BEFORE DELETE` trigger. After commit the status row and the marker are both gone.
- **Delete reference Note.** Normal status removal. Because this Note was federated, normal Delete delivery applies to it. The projection remains.
- **Disconnect identity.** Provider page calls `revoke!` or `delete!` on the vault. Set `disconnected_at`. Delete inbound rows. Delete outbound rows that never left the server (`remote_state` `absent` or `pending_create` with no request sent). Rows that are `present` or `unknown` stay, with no token, so a lost acknowledgment is not rewritten as inactive. Keep public-source projections.
- **Delete user.** In the same transaction, purge that user's projection statuses, then `purge_user!`. `ON DELETE RESTRICT` makes `DELETE FROM users` fail if a marker is still there, which is what the spec asserts for a direct delete that skipped the purge. After the service commits, the user row is gone, no marker remains, and no ActivityPub Delete was enqueued. Credentials cascade from `User`. Subscriptions, identities, groups, and snapshots cascade from `user_id`. Shared sources, resources, and actors stay. There is no private blob to delete. A second user of the same account is not deleted, and that user's projections stay.
- **Delete account.** The service purges every projection of every user of that account in the same transaction, before `purge_user!` and before `purge_statuses!`. `Account#destroy` is not the supported path: the user association is destroyed first, `RESTRICT` aborts it, and the rows stay. When the service keeps the user record and only disables it, the purge still runs, so the other user of the account cannot read those rows through `owned?`.
- **Suspend user.** Workers for that `user_id` no-op. Projections are already owner-only.
- **Mute external actor.** Owner-level `external_actor_mutes` only.
- **Reports.** A projection is not a reportable remote account. The owner's federated reference Note is reportable like any other post.
- **Blocks and domain blocks.** They continue to apply to real accounts. They are not how an RSS host is silenced. An instance that wants to refuse a host does it with the bridge's fetch allow/deny list in a later phase, defaulting to the SSRF checks already in `Request`.

## Deliberately not bridged

- A public or per-user synthetic actor for an external author or feed.
- Cross-user comments, reader lists, favourite counts, or popularity ranks for external resources.
- Copying external body or media into a federated Note.
- Automatic ActivityPub delivery of native inbound likes, replies, or reposts.
- `Announce` of an external URL or of a private projection. `Announce` of the owner's own reference Note is the Fediverse boost, not a share.
- Merging objects because the text or the URL looks similar.
- A Fedibird-operated PDS, hybrid account, or AT account migration.
- Enabling `PostingIdentity` `bluesky`.
- X and mixi2 adapters, until a later issue sets `terms_state`.
- A generic plugin loader or a generic secret POST.
- New values of `Account.protocol`, a `statuses.protocol` column, or `ap_object_type` as a source protocol.
- Putting authenticated bodies or tokens into Redis, Chewy, logs, Sidekiq arguments, REST, or the shared tables. P1 through P3 do not store those bodies anywhere else either.

## Roadmap

Each slice is its own review, flag default **off**, and safe to merge without turning the feature on. Workers no-op while their flag is off. Flags are instance settings, not a hidden default-on path.

| Phase | Flag | Delivers | Depends on | Gate |
| --- | --- | --- | --- | --- |
| P1 | `external_bridge_rss` | Public RSS/Atom subscribe, shared public cache, private projection, fail-closed list, owner extension. No credentials. | This document | The fail-closed list, the user-id read gate, the favourite and bookmark list and destroy specs, the creation transaction, the `external_projection` column, the marker-restrict specs, the physical-purge specs, the flag-without-marker specs, and the Chewy scope specs land in the same change as the writer. The two-users-one-account case is part of that gate. The streaming files in the audit are part of that gate. Flag stays off until those specs pass and the column change has committed. Authenticated feeds are rejected with no shared write. No unique index is added on `statuses(id, account_id)`, and no index is added on `external_projection`. |
| P2 | `external_bridge_atproto` | Provider page, `external_identities`, vault `oauth_session`, discovery and issuer binding. No timeline import and no repo writes. | Registry and vault, which exist now | No token in logs or pages. A session whose `sub`, PDS, and `issuer` do not match is not stored. Catalog shows the provider only when the page exists. |
| P3 | `external_bridge_native_actions` | AT like, repost, reply, and undo against the resolved PDS, with the command log and reconcile rules. | P2 | Opt-in per action. Lost-ack, 401, duplicate-click, and stale-command specs pass. Writes do not target a fixed session host. |
| P4 | `external_bridge_inbound` | Private inbound replies, likes, and reposts for the owner's identity. | P2. Reply-back uses P3. | No `Notification` or remote `Account` rows. |
| P5 | `external_bridge_publication_groups` | Explicit groups of a local status the user selected and native records the user linked after a DID check. Owner-only counts for those records. | P2 for the identity. P3 and P4 only when a count comes from an interaction sync. | No `create_post`. No member inserted from text or URL similarity. Counts are not written to `status_stat` or trends. |
| P6 | `external_bridge_ap_reference` | Reference Notes, scoped auxiliary parents, share `Create`, and boost `Announce` of that Note. | P1, plus the federation experiments | Create, Announce, and Undo are each recorded against a remote Mastodon follower and a relay. Bridgy Fed result recorded. Content template tested. Projection ids absent from ActivityPub. |

X and mixi2 are not a phase. A future issue can add a provider only after `terms_state` is an explicit decision.

P1 verification is the matrix in `docs/private_external_bridge_audit.md`. The P1 migration adds nullable `statuses.external_projection` with no default and does not create an index on it. It does not add a unique index on `statuses(id, account_id)`. The account match is the ordinary `BEFORE` row trigger's primary-key reads of `users` and `statuses`. Callbacks that ask whether a status is private read the column or the marker. The user gate reads the marker through the unique index on `external_status_projections.status_id`.

P2's connection result shows handle, DID, issuer, and PDS origin. It does not print the token, the DPoP key, or the vault error's raw payload. A public read used as a connection check, if any, goes to the resolved PDS or a configured public AppView and does not establish that writes may use that same host.

## Review decisions

These are chosen in this document so P1 can be written without inventing a boundary. They are still open to change before P1 merges.

1. **No phantom actor.** Stock clients show the owner's account on a projection. Confirm or replace with a design that still is not Webfinger-discoverable and still fails `owned?` safely.
2. **Share is one `Create`. Boost is `Announce` of the owner's reference Note, with `Create` only when that Note is new.** Neither announces the external URL or the projection. Undo of a boost does not delete the Note. Remote display of the pair is an experiment, not a claim that followers see one item.
3. **Auxiliary parents are unique per user, resource, and distribution scope, and that scope is frozen.** A wider audience creates a new parent after confirm. Every explicit share is still a new standalone Note.
4. **Disconnect deletes inbound payloads and outbound rows that never left the server (`absent`, or `pending_create` with no request sent), and keeps public RSS projections.** Rows that are `present` or `unknown` stay, with no token. A lost acknowledgment is not rewritten as inactive. Confirm.
5. **AT writes go to the PDS resolved from the DID document. Tokens are not sent to a user-typed URL.** A hostname may start discovery. It becomes a session only after `sub`, PDS metadata, and `issuer` match. App passwords are out of scope. Confirm before P2.
6. **Projection bodies stay out of `StatusesIndex`.** The index scope excludes their ids and `delete_if` removes a loaded object. Favourite, bookmark, and `StatusStat` imports cannot put the id back. `search_indexable?` is not that guard. Owner search of imports needs a later index keyed by `user_id`.
7. **P1 does not download external media into `media_attachments` or public system paths.**
8. **Ordinary personal-status Delete reach is unchanged by P0.** Projection deletion must not use it. A fix for ordinary personal deletes is a separate issue.
9. **X and mixi2 stay unreviewed.** No implementation schedule is implied.
10. **Bridgy Fed behavior with a link Note, and remote display of `Create` plus `Announce`, are experiments, not guarantees.**
11. **A projection is readable only by its `user_id`.** Account ownership, `owned?`, the author short-circuit in `StatusFilter`, and an account-level favourite, bookmark, or emoji-reaction row are not sufficient. List and destroy actions re-check the user. Two users of one account do not share projections. This feature does not add a unique index on `users.account_id`.
12. **Boost is refused for direct and limited.** Reply and quote may still use those parent scopes. `ReblogService` and `StatusPolicy#reblog?` are not bypassed.
13. **P5 does not create native posts.** A native group member is an AT URI the user submitted whose repo DID matches the linked identity. Like, repost, and reply records are not members.
14. **Each native intent has its own immutable command key.** A replay after a newer command is `superseded` or `stale_activity_command` and does not write to the PDS.
15. **`projection_private?` is `external_projection` true or a marker.** Either one skips `store_uri`, create and update webhooks, workers, serializers, policy, filters, lists, the index, deletion reach, trends, and export. A true column with no marker is not readable by anyone, including the account holder. Repair is a physical purge. The marker's `user_id` is `ON DELETE RESTRICT`.
16. **No full unique index on `statuses(id, account_id)`, and no partial index on `external_projection`.** The account match is an ordinary `BEFORE INSERT OR UPDATE` row trigger with `FOR SHARE` on the user and status rows. It is not a constraint trigger. Existing `(id, account_id)` indexes are partial and are not a foreign-key target. The boolean is read from the primary-key tuple.
17. **Projection removal is a physical `DELETE` in the same transaction as any following user delete.** `discard` and `RemoveStatusService` are not success. The purge sets `fedibird.projection_status_delete` and then deletes the status, which cascades the marker. Rollback leaves both rows. After the user-delete service commits, `DELETE FROM users` has succeeded and no ActivityPub Delete was enqueued.

## What P1 can take from this document without guessing

- The owner is `user_id`. The status account is that user's real local account. There is no synthetic actor.
- The shared cache has no user id and no authenticated body. A private fetch does not create a shared row.
- The projection status is a different row from the reference Note. Only the reference Note has an ActivityPub URI. A Fediverse boost announces that Note.
- The status row and its projection marker commit together, or neither does. `store_uri` and both webhook callbacks return when the column is true or a marker exists, including after the marker has been removed. The Chewy document stays absent because the index scope excludes the id, including after favourite and bookmark. P1 does not publish the projection to Redis.
- The reader passes a user id. The other user of the same account receives not-found, including on favourite, bookmark, and emoji-reaction lists, and cannot destroy those rows. A true column with no marker is not-found for the owner too.
- `external_projection` is set on insert. There is no index on that column. The marker is not removed while the status exists. User deletion physically deletes the projection status in the same transaction, then deletes the user.
- The account match is an ordinary `BEFORE` row trigger. P1 does not build a unique index on `statuses(id, account_id)`.
- Favourite and bookmark are local unless a later opt-in says otherwise, and only the projection's user can create or destroy them.
- Reply, boost, and quote of a projection are refused on the ordinary API.
- Secrets stay in the vault. The identity table is the connection.
- The fail-closed list is part of P1, not a follow-up, and the RSS flag stays off until it is tested.
