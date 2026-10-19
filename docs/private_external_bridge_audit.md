# Private external-bridge code-path audit

Baseline: `f583dd2a795f7e66dc3971c6b9203bda2f2fd69a` on `fedibird`. Read from that tree. This audit does not change runtime behavior and does not claim a guard exists unless the cited method implements it.

The contract these findings support is `docs/private_external_bridge.md`.

Labels:

| Label | Meaning |
| --- | --- |
| CONFIRMED | The cited method does this on the baseline. Not a runtime re-execution of the app. |
| RISK | What happens if a private projection is stored as an ordinary status and hits this path. |
| GAP | A guard this design needs and the baseline does not have. |
| UNVERIFIED | Not established by reading this path. Later phases need a spec or an experiment. |

`visibility = personal` is the closest existing control. It is owner-account-only in `StatusPolicy#show?`, and several publishers never look at it. A projection marker has to be checked on its own.

## Status model

CONFIRMED. `app/models/status.rb`.

| Symbol | Lines | Behavior |
| --- | --- | --- |
| `visibility` / `searchability` enums | 65–72 | `personal` is 200. `UNCOUNT_VISIBILITY` is `direct` and `personal`. `personal` is not in `STANDARD_VISIBILITY`. |
| `update_index('statuses', :proper, if: :search_indexable?)` | 63 | Chewy update hook. |
| `search_indexable?` | 396–398 | True unless `ap_page?`. No visibility check. |
| `local?` | 331–333 | `attributes['local']` or `uri.nil?`. |
| `object_type` | 379–381 | `:comment` if reply, otherwise `:note`. Ignores `ap_object_type`. |
| `ap_object_type` | 383–394 | Stored `page`, or null meaning `note`. |
| `distributable?` / `hidden?` | 425–430 | Public or unlisted only. Personal is hidden. |
| `searchable_by` | 214–238 | Local author `account_id`, plus local favourites, reblogs, bookmarks, mentions, reactions, votes, references. |
| `store_uri` | 899–901 | After create, if `local?`, sets `uri` from `ActivityPub::TagManager#uri_for` when `uri` is nil. |
| Counter callbacks | 670–679, 971–978 | `increment_counter_caches` skips `uncount_visibility?` and pages. `store_uri`, statistics, and webhook callbacks are separate. |
| `trigger_create_webhooks` / `trigger_update_webhooks` | 999–1005 | Enqueue for every local non-page status. No `personal` check. |
| `permitted_for` | 765–785 | Author gets `all`. Others get public, unlisted, private if following, plus any status they are mentioned in. `personal` is not in the visibility list. |

There is no `Status#protocol` and no `statuses.protocol` column. `Account.protocol` is only `:ostatus` and `:activitypub` (`app/models/account.rb` line 108). `Account#local?` is `domain.nil?` (lines 199–201).

RISK. A local projection created with `Status.create!` gets an ActivityPub URI, a Chewy document, and a webhook even when visibility is personal. Account post counters skip personal. The URI is `account_status_url` for a note (`ActivityPub::TagManager#uri_for`, lines 37–48).

GAP. `store_uri` and both webhook callbacks must no-op when `external_projection` is true or a marker exists. A missing marker is not permission to set `uri` or enqueue. `search_indexable?` returning false is not sufficient; the index scope has to exclude the id. `permitted_for`'s author branch and mention branch must not return a private projection, including a true column with no marker.

`store_uri` and the webhooks are `after_create_commit` (lines 673 and 678–679). They run only after a successful commit. Chewy is not in that set. `config/initializers/chewy.rb` line 25 sets `Chewy.use_after_commit_callbacks` to false, so `update_index` is an `after_save` hook and `if: :search_indexable?` runs inside the transaction, before a marker inserted afterwards. The P1 writer inserts the status and the marker in that same transaction and does not commit the status in a nested transaction. A failed marker insert rolls both back, so `after_create_commit` does not run. Chewy's post-commit import is specified in the timelines section: the index scope excludes the id, and an import of a missing id deletes rather than inserts. Owner streaming is not produced by a successful commit.

## Account versus User

CONFIRMED. The policy object is an Account, and the database allows more than one User on that Account.

| Symbol | Lines | Behavior |
| --- | --- | --- |
| `AccountAssociations` `has_one :user` | `app/models/concerns/account_associations.rb` 8 | Association only. No unique index is declared here. |
| `index_users_on_account_id` | `db/schema.rb` 1824 | Not unique. |
| `StatusPolicy#initialize` / `#owned?` | `app/policies/status_policy.rb` 4–8, 75–77 | Compares `author.id` with `current_account.id`. |
| `StatusFilter#filtered?` | `app/lib/status_filter.rb` 14–16 | Returns visible when the viewer account is the author, before `show?`. |
| `Status.permitted_for` | `app/models/status.rb` 772–773 | Author account receives `all`. |
| `Status.permitted_statuses_from_ids` | 754–763 | Builds `StatusFilter` from an account id. |
| `Account#permitted_statuses` | `app/models/account.rb` 513–519 | Author starts from every status of the account, then `permitted_for`. |
| `PersonalFeed#personal_scope` | `app/models/personal_feed.rb` 51–53 | `account_id` and personal visibility. No user id. |
| `AccountStatusesFeed#permission_scope` | `app/models/account_statuses_feed.rb` 16–19 | `permitted_statuses(viewer)`. |
| `Api::V1::StatusesController#set_status` | `app/controllers/api/v1/statuses_controller.rb` 166–174 | `authorize :show?` after `Status.find`. |
| `current_account` | `app/controllers/application_controller.rb` 142–146 | `current_user&.account`. |
| OAuth resource owner | `app/controllers/api/base_controller.rb` 114–119 | `User.find(doorkeeper_token.resource_owner_id)`. |
| `BackupService` outbox | `app/services/backup_service.rb` 30 | Iterates `account.statuses`. `User` has `has_many :backups`. |

`User` has `belongs_to :account` (`app/models/user.rb` line 83) and no uniqueness validation on `account_id`.

RISK. A second user row with the same `account_id` passes `owned?`, the `StatusFilter` author short-circuit, `PersonalFeed`, and `Account#permitted_statuses`. Those paths would render user A's projection to user B.

GAP. `projection_private?` is the column or a marker. `ProjectionAccess.allow?` requires a marker and `viewer_user_id == external_status_projections.user_id`. Nil user id denies. A true column with no marker is not-found for every caller, including the account holder. The paths in the table exclude or 404 a private projection unless `allow?` passes. The account match is an ordinary `BEFORE INSERT OR UPDATE OF user_id, account_id, status_id FOR EACH ROW` trigger, not a constraint trigger, and it takes `FOR SHARE` on that user and that status. This feature does not add a unique index on `users.account_id` or on `statuses(id, account_id)`.

## Account-scoped favourite, bookmark, and reaction lists

CONFIRMED. These actions load by `account_id` and return status bodies. Destroy of an existing favourite or bookmark does not call `authorize`.

| Symbol | Lines | Behavior |
| --- | --- | --- |
| `Api::V1::FavouritesController#index` | `app/controllers/api/v1/favourites_controller.rb` 8–16, 44–46 | `current_account.favourites`, then `REST::StatusSerializer` or the compact serializer. No policy. |
| `Api::V1::BookmarksController#index` | `app/controllers/api/v1/bookmarks_controller.rb` 8–16, 44–46 | `current_account.bookmarks`. Same render. |
| `Api::V1::EmojiReactionsController#index` | `app/controllers/api/v1/emoji_reactions_controller.rb` 24–33, 99, 123 | Lines 24–33 render the statuses. Lines 99 and 123 load `current_account.emoji_reactions`. |
| `Statuses::FavouritesController#destroy` | `app/controllers/api/v1/statuses/favourites_controller.rb` 17–27, 37 | A found favourite skips `authorize`, enqueues `UnfavouriteWorker`, and the action renders that status at line 37. `authorize :show?` runs only when no favourite exists. |
| `Statuses::BookmarksController#destroy` | `app/controllers/api/v1/statuses/bookmarks_controller.rb` 15–27 | A found bookmark skips `authorize`. `destroy!` is line 25 and the render is line 27. `authorize :show?` runs only when no bookmark exists. |
| `UnfavouriteWorker#perform` | `app/workers/unfavourite_worker.rb` 6 | Arguments are `account_id` and `status_id`. |
| `UnfavouriteService#call` | `app/services/unfavourite_service.rb` 7–8 | Destroys the account's favourite. No policy. |
| `Statuses::EmojiReactionsController#set_status` | `app/controllers/api/v1/statuses/emoji_reactions_controller.rb` 30–32 | `authorize :show?`, which is the account policy. |

RISK. User B, sharing user A's account, receives A's projection from `GET /api/v1/favourites`, bookmarks, and emoji reactions, in compact mode as well. `DELETE` of that favourite or bookmark destroys A's row and renders the body. `show?` does not stop B, because `owned?` is true for the account.

GAP. Those lists filter with `ProjectionAccess`. Destroy returns 404 and keeps the row when the user id does not match, and does not render the body. `UnfavouriteWorker` carries `user_id`. An account-only job does not destroy a projection favourite and does not serialize it.

## Marker lifetime and the statuses indexes

CONFIRMED.

| Symbol | Lines | Behavior |
| --- | --- | --- |
| `DeleteAccountService#purge_content!` | `app/services/delete_account_service.rb` 143–146 | `purge_user!` then `purge_statuses!`. |
| `purge_user!` | `app/services/delete_account_service.rb` 135–139 | Destroys the user when the email is not kept. |
| `purge_statuses!` | `app/services/delete_account_service.rb` 172–175 | `BatchedRemoveStatusService` on the account's statuses. |
| `AccountAssociations` | `app/models/concerns/account_associations.rb` 8, 15 | `has_one :user, dependent: :destroy` is declared before `has_many :statuses, dependent: :destroy`. Account destroy removes the user first. |
| `index_statuses_local_20190824` | `db/schema.rb` 1592 | Partial index on `(id, account_id)`. Visibility public, local or null `uri`, not deleted, not a reblog, reply constrained. Not unique. |
| `index_statuses_public_20200119` | `db/schema.rb` 1593 | Partial index on `(id, account_id)`. Visibility public, not deleted, not a reblog, reply constrained. Not unique. |
| `Status` discard | `app/models/status.rb` 44, 57 | `Discard::Model`. `discard_column` is `deleted_at`. Discard updates that column. It is not a `DELETE`. |
| `RemoveStatusService#call` | `app/services/remove_status_service.rb` 24, 40, 61, 226–228 | Discards, then may call `remove_from_remote_reach`, then `destroy!` only when `permanently?`. |
| `BatchedRemoveStatusService#call` | `app/services/batched_remove_status_service.rb` 34 | `Status.where(id: ...).delete_all`. Physical delete, but this service does not set the projection-delete setting, and account deletion calls it only after `purge_user!`. |
| Favourite, bookmark, emoji-reaction status FKs | `db/schema.rb` 1911, 1930, 1937 | `ON DELETE CASCADE` from the status row. A physical status delete removes those rows. Discard does not. |

RISK. A `user_id` `ON DELETE CASCADE` on the marker deletes it inside `purge_user!`, before `purge_statuses!`. The status remains. Removal then follows the ordinary personal path, including follower delivery. Account destroy has the same order, because the user association is destroyed before statuses. The same gap exists if one of two users is destroyed and the account stays: the marker goes, the status stays, and the other user passes `owned?`. Discarding the status instead of deleting it leaves the marker, so `RESTRICT` then blocks user deletion, and `RemoveStatusService` can already have delivered Delete.

GAP. `user_id` is `ON DELETE RESTRICT`. The purge `SET LOCAL fedibird.projection_status_delete = 'on'` and then physically `DELETE`s the status rows in the same transaction as the following user delete. That cascade removes the marker. An ordinary `BEFORE DELETE` row trigger, not a constraint trigger, rejects a marker delete while the status exists unless that setting is on. `discard` and `RemoveStatusService` are not the purge. A direct marker delete while the status exists is rejected. A status left with `external_projection` true and no marker is not-found for every caller, including the former owner, and is not indexed, not given a `uri`, and not webhooked. Repair is the same physical `DELETE`. No unique index is added on `statuses(id, account_id)`, and no index is added on `external_projection`. The partial indexes above are not a foreign-key target. The account-match trigger is an ordinary `BEFORE` row trigger with `FOR SHARE`.

## Status policy and serializers

CONFIRMED. `app/policies/status_policy.rb`.

```17:31:app/policies/status_policy.rb
  def show?
    return false if record.ap_page?
    return false if author.suspended?
    return false unless expired_show?

    if personal?
      owned?
    elsif requires_mention?
      owned? || mention_exists?
    elsif private?
      owned? || following_author? || mention_exists?
    else
      current_account.nil? || (!author_blocking? && !author_blocking_domain?)
    end
  end
```

`owned?` is `author.id == current_account&.id` (lines 75–77). It is the status account, not `users.id`. `favourite?` is `show?` and not blocking (lines 41–43). `reblog?` also requires `show?` and rejects the mention-required visibilities (lines 37–39). There is no `quote?` or `bookmark?` policy method.

`StatusFilter#filtered?` returns false immediately when the viewer account id equals the status account id, before `show?` (`app/lib/status_filter.rb` lines 14–18). Pages are excluded first. A nil viewer does not take that branch, so `show?` runs and personal is hidden.

`expired_show?` allows the owner, a favouriter, a bookmarker, an emoji reactor, or a mentioned account (policy lines 33–35). A stale favourite from the owner is fine. A stale favourite from someone else must not become a way to read a projection. Projection favourites are owner-only, and non-owner favourite rows are a bug.

REST mask, CONFIRMED `app/serializers/rest/status_serializer.rb` lines 142–157: `personal` is serialized as `direct`, with the real value in `visibility_ex`.

ActivityPub note type, CONFIRMED `app/serializers/activitypub/note_serializer.rb` lines 43–47: raises `Status::UnreleasedActivityObject` for a page, otherwise `Note` or `Question`. Lines 210–212: serializer `local?` is `object.account.local?`. A personal note serializes as a normal Note if a caller reaches the serializer.

RISK. Policy hides personal from other accounts only when `show?` is actually called. Feed hydration, webhook delivery, backup export, and admin trend approve do not use this policy. `owned?` cannot express "this user, even if `account_id` matches a different login". `users.account_id` is not unique (`db/schema.rb` line 1824, `index_users_on_account_id`).

GAP. Projection checks use `external_status_projections.user_id`. Non-owners, including staff trend endpoints, get not-found rather than a body.

## Account and surrogate actors

CONFIRMED.

- `User belongs_to :account` (`app/models/user.rb` line 83). `Account` `has_one :user` for local users.
- Remote accounts are `domain` present and normally have no user.
- `PostingIdentity::KNOWN_KINDS` includes `bluesky`. `ENABLED_KINDS` is only `local` (`app/services/posting_identity.rb` lines 13–14). No AT Protocol client exists in this tree. Search of the application code found no `atproto` implementation.
- RSS in the product is outbound. `AccountsController#default_statuses` is public and unlisted only (lines 76–78). There is no subscribed-feed importer. `Import` types do not include an external feed.
- Webfinger (`config/routes.rb` line 40, `WellKnown::WebfingerController`) publishes a local account. A synthetic local username would be discoverable. This design does not create one.
- Block, mute, and domain block operate on `Account` ids and domains (`BlockService`, `MuteService`, `BlockDomainService`). They do not mute an RSS host or a DID.

RISK. A projection attached to any account other than the single owning user fails `owned?` for that user or succeeds for the wrong user. A local account with `user` nil will raise in `FanOutOnWriteService` when it calls `status.account.user.setting_hide_direct_from_timeline` (line 23) or the personal setting (line 26).

GAP. No `accounts` row for external authors. Mutes of external authors are `external_actor_mutes`, not `Block`.

## REST, context, and account listings

CONFIRMED unless marked otherwise.

| Entrance | Authorization | Projection note |
| --- | --- | --- |
| `Api::V1::StatusesController#set_status` | `Status.include_expired.find`, then `authorize :show?`. Not-found on `Mastodon::NotPermittedError`. | Personal is owner-only **if** `show?` runs. Guessable ids still hit `find` first. |
| Context ancestors and descendants | `Status.permitted_statuses_from_ids` then `StatusFilter`. | Policy applies. A projection must not be returned as part of another status's thread. |
| `Api::V1::Accounts::StatusesController` | `AccountStatusesFeed#permission_scope` calls `permitted_statuses` and optionally `without_personal_visibility`. | Author scope includes personal. Other viewers do not, unless `permitted_for` matches a mention. |
| `ActivityPub::OutboxesController` | `permitted_for(@account, signed_request_account)` around line 65. | Same mention gap. |
| Favourites and bookmarks index | Current user's rows, no second policy pass. | Safe only if a non-owner cannot create the join row. |
| `Api::V1::Statuses::FavouritedByAccountsController#set_status` | `authorize :show?` (lines 70–74). | Owner-only for personal. Still a reader list of that status. Projections must not be aggregated across users. |
| `Api::OEmbedController` | Unauthenticated. `require_public_status!` rejects `hidden?` (lines 19–21). | Personal is hidden, so oEmbed 404s. The finder loads the row first. |
| HTML `StatusesController#show` | `authorize :show?` or capability token. | Non-owner personal is 404. |
| HTML and RSS profile | `visibility: [:public, :unlisted]` (accounts controller lines 76–78). | Personal excluded. |
| Embed | Hidden statuses 404. | Personal excluded from the public embed. |
| `PersonalFeed#personal_scope` | `account_id` of the viewer and `with_personal_visibility` (lines 51–53). | Shows the owner's personal statuses, and would show projections on that account. That is the intended owner surface if the product places them there. |
| Public and tag feeds | `with_public_visibility`. | Personal excluded. |

`Account#permitted_statuses` (`app/models/account.rb` lines 513–519) uses the full account scope for the author and then `permitted_for`.

GAP. Every list above needs a projection exclusion for non-owners, including the mention branch. Owner personal-timeline inclusion is allowed. Public RSS, oEmbed, embed, and profile HTML must keep excluding them even if visibility is wrong.

Node streaming is not an authorization layer for projections. CONFIRMED in `streaming/index.js`:

| Path | Lines | What it actually checks |
| --- | --- | --- |
| `channelNameToIds`, case `user` | 1057–1061 | Subscribes to `timeline:${accountId}` for the token's account. `needsFiltering` is false. |
| `channelNameToIds`, case `direct` | 1397–1401 | `timeline:direct:${accountId}`. `needsFiltering` is false. |
| `channelNameToIds`, case `list` | 1429–1437 | Authorizes list ownership, then `timeline:list:${id}` with `needsFiltering` false. |
| `streamFrom` | 824–827 | When `needsFiltering` is false, or the event is not `update` / `status.update`, the payload is transmitted as published. |
| Public, hashtag, and group cases | 1083 and following | `needsFiltering` true. The filter at 844–880 is block, mute, domain block, and keyword filters. It does not read `visibility` or a projection marker. |
| `checkScopes` | 531–560 | Public channel names skip OAuth scopes. User channels require `read` or `read:statuses`. |

A payload Ruby publishes on `timeline:public` or on another account's `timeline:{id}` is delivered to whoever is allowed to subscribe to that Redis channel. The Node process will not notice that the status is a projection. P1's gate is that the writer publishes nothing. Owner-only streaming is not established by these files, and a live owner channel is not a P1 deliverable. A later phase that wants one has to name the Redis channel and prove a second account's user stream does not receive it.

## Timelines, Redis, streaming, search

CONFIRMED.

`FanOutOnWriteService#call` (`app/services/fan_out_on_write_service.rb`):

- Returns immediately for `ap_page?` (line 17).
- Delivers to self unless the status is direct and the user hides direct (line 23). That self delivery runs **before** the personal branch.
- Personal then delivers to self-included lists unless `setting_hide_personal_from_timeline`, and returns (lines 25–27). No follower, public, hashtag, or media firehose delivery.

`Feed#filtered_scope` (`app/models/feed.rb` lines 78–83) loads status ids and optionally filters a visibility list. It does not call `StatusPolicy`.

`PushUpdateWorker#perform` (`app/workers/push_update_worker.rb` lines 7–14) loads the status and renders it to `timeline:{account}` with no policy check.

`StatusesIndex` stores `searchable_by` and `searchability` (`app/chewy/statuses_index.rb` lines 215–216). Personal text is indexed because `search_indexable?` allows it. `SearchQueryTransformer` can restrict queries to `searchable_by` of the current account. That is a query filter, not an index-time exclusion.

`index_scope` is `Status.include_expired.without_reblogs.reorder(nil).with_includes` (line 133). It does not exclude a projection.

CONFIRMED indirect reindex, Chewy 7.6.0. `Chewy.use_after_commit_callbacks` is false, so these callbacks are `after_save` / `after_destroy`, and the Sidekiq worker calls `StatusesIndex.import!` with ids. `Orm#import_objects` reloads those ids through `index_scope`. An id the scope does not return is a delete. `direct_import` is unset in this app. `delete_if` on the scope is what deletes an object that was loaded anyway.

| Caller | Lines | Filter |
| --- | --- | --- |
| `Status` | `app/models/status.rb` 63 | `if: :search_indexable?`, which is `!ap_page?` (lines 396–398) |
| `Favourite` | `app/models/favourite.rb` 16 | none |
| `Bookmark` | `app/models/bookmark.rb` 16 | `if Chewy.enabled?` at class load, then none |
| `StatusStat` | `app/models/status_stat.rb` 21 | none. Favourite count updates reach this row |
| `Mention` | `app/models/mention.rb` 17 | none |
| `StatusReference` | `app/models/status_reference.rb` 16 | indexes `target_status` |
| `PreviewCard` | `app/models/preview_card.rb` 69 | indexes the joined statuses |

No other file under `app/models` calls `update_index('statuses')`.

RISK. A projection that survives create with no document is inserted when the owner favourites or bookmarks it, and again when `status_stat.favourites_count` changes. A full import of the current scope inserts it too. Setting `search_indexable?` false does not stop those callers.

GAP. The scope gains `where.not(id: ExternalStatusProjection.select(:status_id))` and `delete_if` on the marker. P1 does not pass `direct_import: true`. The post-commit import of a new projection id deletes a document that already exists. The spec asserts a raw document get after create, favourite, bookmark, unfavourite, unbookmark, and a full scope import.

`PublishStatusService` (`app/services/publish_status_service.rb`):

- Skips mention delivery for personal (lines 48–50).
- Always enqueues `DistributionWorker` (lines 54–59).
- Skips `ActivityPub::DistributionWorker` for personal (line 61).
- Always enqueues `LinkCrawlWorker` (lines 64–67).

RISK. A projection published through `PostStatusService` lands on the owner's home Redis feed and streaming channel, is link-crawled, and is indexed. If its id is ever written into another account's feed ZSET, `Feed#filtered_scope` will render it. If visibility is anything but personal, follower and public fan-out run.

GAP. The projection writer must not call `PublishStatusService`. Index and link-crawl hooks must skip the marker even if a later bug calls them. Feed reads must drop projection ids unless `viewer_user_id` matches the marker. The author account is not that match.

## ActivityPub

CONFIRMED.

| Symbol | Lines | Behavior |
| --- | --- | --- |
| `ActivityPub::TagManager#uri_for` / `#url_for` | 20–56 | Local notes become account status URLs. Remote objects return their stored `uri` / `url`. |
| `#to` | 102–117 | `public`, `unlisted`, `private`, `limited`, `direct` are explicit. `personal` and `mutual` fall through to `[]`, then an audience account may be appended. |
| `#cc` | 135–150 | Mentions are added only for `FOLLOWER_VISIBILITY` (public, unlisted, private). |
| `#searchable_by` | 152–166 | Non-public/unlisted/private/limited searchability becomes `[uri_for(account)]` plus mentions. Personal lands here. |
| `ActivityPub::DistributionWorker#skip_distribution?` | 28–30 | Skips `direct` and `ap_page?` only. **Does not skip `personal`.** |
| `ActivityPub::StatusUpdateDistributionWorker#skip_distribution?` | 24–26 | Skips `personal` and pages. |
| `UpdateStatusService#broadcast_updates!` | 220–226 | Enqueues `PriorityDistributionWorker` or `DistributionWorker` for every visibility. Skips the ActivityPub update worker when the status is personal. |
| `ActivityPub::Activity#visibility_from_audience` | 316–327 | Empty `to` and `cc` become `:personal`. Other non-matching audiences become `:direct`. |
| `RemoveStatusService#remove_from_remote_reach` | 116–127 | `StatusReachFinder` with `unsafe: true`, then `DeliveryWorker` of Delete or Undo. No personal check. Called for local non-page statuses (line 40). |
| `StatusReachFinder#followers_inboxes` | 76–84 | Direct and limited return empty only when not `unsafe`. Unsafe personal therefore uses `delivery_followers.inboxes`. |
| `ActivityPub::DeleteSerializer#to` | 39–44 | Addresses Public, plus an audience account if present. Tombstone id is `uri_for(status)`. |
| `ReblogService` | 20–29, 41–50 | Returns an existing reblog for the same account and target. Rejects `personal`. Hidden originals keep their visibility. Otherwise creates a status and enqueues both distribution workers. |
| `ActivityPub::ActivityPresenter.from_status` | `app/presenters/activitypub/activity_presenter.rb` 7–23 | A reblog is type `Announce` (line 10). The object is the original URI, unless the author boosts their own local private status, in which case the Note is inlined (lines 18–20). |
| `FeedManager#add_to_feed` | `app/lib/feed_manager.rb` 533–539 | A reblog is not inserted when the original is already within `REBLOG_FALLOFF` of the top of that local feed. |
| `ActivityPub::UndoAnnounceSerializer` | `app/serializers/activitypub/undo_announce_serializer.rb` 9–26 | Undo of a reblog targets the Announce. It is not a Delete of the original. |
| `BackupService` | 30 | Exports `account.statuses.without_unreleased_pages` as ActivityPub activities. Personal statuses are included. |

Inbound Create can store a remote status as personal when both audience arrays are empty. That is existing ingest, not this bridge. Those rows are remote (`uri` present) and are not projections.

RISK. Enqueueing `ActivityPub::DistributionWorker` for a personal status will deliver it. Deleting a personal status delivers a Tombstone id to follower inboxes, addressed to Public. The tombstone does not include the status text. It does publish the object id. Backup export serializes personal text as a Note. `TagManager#to` being empty does not stop a worker that already decided to deliver to followers.

GAP. Projection `uri` stays null. Distribution, update distribution, delete reach, outbox, and backup must skip the marker. `ActivityPub::DistributionWorker` should also skip `personal` so a personal status cannot federate by a direct enqueue. That personal skip is a small hardening of current code; it is specified because the projection must not depend on every caller remembering. Shipping it changes delete-unrelated delivery of personal statuses that were manually enqueued. It does not change `PublishStatusService`, which already avoids the enqueue. Call it out in the P1 review as a behavior change limited to a path that is already incorrect for personal.

UNVERIFIED. What a remote server does when it receives that Delete today. What Bridgy Fed does when a later reference Note contains a Bluesky or RSS URL. `Formatter#format_bridgy_fed` (`app/lib/formatter.rb` lines 192–203) only rewrites display HTML for content already on a status. It is not an outbound bridge.

## Favourite, bookmark, boost, reply, quote, reference

CONFIRMED.

`FavouriteService#call` (`app/services/favourite_service.rb` lines 11–44):

- Authorizes `:favourite?`.
- Creates `Favourite`.
- `Trends.statuses.register(status)`.
- Local author: `NotifyService` to that account. Remote ActivityPub author: `ActivityPub::DeliveryWorker` with `LikeSerializer`.
- Records a moderation interaction.

`Trends::Statuses#eligible?` (lines 108–110) requires public visibility, a discoverable account, and several other public-trend conditions. A personal favourite therefore registers and then fails eligibility. The register call still runs.

`UnfavouriteService` sends Undo only when the author is remote ActivityPub.

Bookmarks: `Api::V1::Statuses::BookmarksController` creates a row after `show?`. No delivery worker and no notification. CONFIRMED by the controller and the absence of an ActivityPub call on `Bookmark`.

`ReblogService` rejects `visibility == 'personal'` (line 41) and rejects pages. Hidden originals inherit the original visibility. A public reblog enqueues federation and `Trends.register!`.

`PostStatusService` skips mention prepare for personal (`app/services/post_status_service.rb` line 165) and then `PublishStatusService` link-crawls anyway. A reply is a new status. If that reply is public and `in_reply_to` a projection, federation would point at the projection URI once `store_uri` has filled it.

`ProcessStatusReferenceService` resolves status ids only for `public`, `unlisted`, and `private` (line 44). Personal ids are not resolved by that list. Quote is a separate `quote_id` path on `PostStatusService` and is serialized on the Note.

`EmojiReactionService` notifies a local author (line 58) and delivers to a remote ActivityPub inbox (line 67).

RISK. Local favourite of a projection notifies the owner and bumps `favourites_count` on that status. That count is visible to anyone who can `show?` the status. It must not be copied onto `external_resources` or summed across users. A public reply or quote targeting the projection federates. Emoji reaction on a projection notifies or delivers if the service is left unchanged.

GAP. Ordinary reply, boost, quote, reference, and emoji reaction against a projection return 422. Local favourite and bookmark stay. Native like/repost/reply are separate `external_activities` and are not these services.

## Notifications, Sidekiq, webhooks

CONFIRMED.

`Webhook::EVENTS` includes `status.created` and `status.updated` (`app/models/webhook.rb` lines 18–26). Payload rendering uses the REST status serializer from the webhook worker path. No visibility filter on the model callback.

`NotifyService` publishes `timeline:{recipient.id}` for a notification. Favourite notifications are not dropped by the feed filter (`blocked_favourite?` is false).

Workers a normal create can enqueue, CONFIRMED from `PublishStatusService`, `PostStatusService`, and `FanOutOnWriteService`:

- `DistributionWorker` / `PriorityDistributionWorker`
- `ActivityPub::DistributionWorker`
- `LinkCrawlWorker`
- `FeedInsertWorker` / `PriorityFeedInsertWorker`
- `LocalNotificationWorker`
- `ActivityPub::DeliveryWorker`
- `TriggerWebhookWorker`
- `StatusReferenceResolveWorker` when references are processed

Favourite additionally uses `ActivityPub::DeliveryWorker` or `NotifyService`, and `UnfavouriteWorker`. Reblog uses both distribution workers, `LocalNotificationWorker`, and on undo `RemovalWorker`.

`UserCredentialVault` already states the job rule (`app/services/user_credential_vault.rb` lines 21–27): arguments are `owner_user_id`, `credential_id`, `provider`, `purpose`, and `credential_type`. No plaintext. Adapters must not take a credential and an arbitrary URL.

RISK. Any local projection insert that runs the status callbacks notifies webhook subscribers with the private text. Mention and reblog notifications would reveal the object to other local users.

GAP. No webhook and no `NotifyService` to any account except, if the product wants it, the owner. Native inbound must not call `NotifyService` or create `Notification` rows. Sidekiq arguments for fetch jobs follow the vault rule.

## Preview cards, trends, and stats

CONFIRMED.

- `PreviewCard` is unique on `url` and HABTM `statuses` (`app/models/preview_card.rb` lines 74 and 78). One global card per URL.
- `FetchLinkCardService` attaches that card and calls `Trends.links.register` with no visibility check (lines 70–79). The HTTP fetch uses the status text's URLs.
- `Trends::Links#register` (lines 50–59) scores only when both the status and its original are public, not silenced, and not sensitive or spoiled.
- `Trends::Statuses#eligible?` requires public (lines 108–110).
- Account `statuses_count` skips `UNCOUNT_VISIBILITY` on create. `status_stat.favourites_count` and `reblogs_count` still move when those interactions are created. REST exposes them on a status the viewer can see.
- Redis trend keys are global (`activity:links:{preview_card_id}:...` via `Trends::History`). They count accounts that used a public card. They must not receive projection account ids.

RISK. Link-crawling a projection stores a global card (title, description, image) for a URL found in private text, and may fetch a URL that was not meant to be requested on behalf of the server. A public reference Note is allowed to crawl its canonical URL and may trend under the existing public rule. Mixing projection text into that card would publish private text as trend metadata.

GAP. Projections never call `FetchLinkCardService` and never join `preview_cards`. They never call `Trends.statuses.register` or `Trends.links.register`. Public reference Notes may. Native reaction counts go to `external_reaction_snapshots`, not `status_stat`.

## Media, cache, and retention

CONFIRMED.

- Remote AP media is downloaded by `RedownloadMediaWorker` onto `MediaAttachment` and served from instance media paths.
- `Request` (`app/lib/request.rb`) rejects private addresses through `PrivateAddressCheck`, with an exception list. `Mastodon::HostValidationError` exists.
- Personal DeepL caches are partitioned by user, credential, and binding (`docs/user_external_credential_vault.md`, `docs/personal_deepl_translation.md`). Shared translation keys are separate.
- `RemoveStatusService` destroys or discards the status and unpushes feeds. Remote reach is the gap above. Chewy follows the model callback rather than an explicit purge in that service.
- There is no `DeleteStatusService`. Removal is `RemoveStatusService` via `RemovalWorker`.

RISK. A projection that created `MediaAttachment` rows or preview images would publish those files on the usual media URLs. Authenticated feed bodies placed in `Rails.cache` or Redis without the user and binding id would leak across users.

GAP. P1 stores text on the projection and, only after a public 2xx fetch, on the shared resource. It does not download media. An authenticated or failed fetch writes no shared row and no private blob. That private model is not specified here. Deletion of a projection does not deliver ActivityPub and does not delete the shared public resource.

UNVERIFIED. Exact Paperclip/filesystem cache headers for a hypothetical private attachment. Not needed for P1 because no attachment is created.

## Auth, vault, and provider connections

CONFIRMED.

- Vault API: `store!`, `replace!`, `with_credential`, `revoke!`, `delete!` on `UserCredentialVault`. Owner, classification, revocation, and expiry are checked before decrypt. `binding_id` is inside the authenticated purpose.
- `User has_many :external_credentials, dependent: :destroy` (`app/models/user.rb` line 98). FK cascade is in the vault migration described by `docs/user_external_credential_vault.md`.
- `ExternalServices::Registry::PROVIDERS` is only `DeepL`. Routes are the hub, the catalog, and DeepL-specific mutations (`config/routes.rb` lines 156–163). No generic secret POST.
- DeepL reads safe columns for hub cards and does not decrypt in the registry.
- Sudo on those settings mutations drops the submitted secret when the challenge is missing.
- No Bluesky, X, or mixi2 credential type is implemented. Twitter text and Open Graph `twitter:player` handling in link cards are not an X API client.

GAP. `external_identities` is the future connection row. It stores `credential_id`, never the secret. Provider, purpose, and credential type are chosen by the provider controller. X and mixi2 cannot be added by setting `terms_state` from a request parameter.

## Admin and export paths

CONFIRMED.

`Api::V1::Admin::Trends::StatusesController#approve` and `#reject` (lines 20–33) `Status.find` and render the admin trend serializer after `authorize [:admin, :status], :review?`. `Admin::StatusPolicy#review?` is only `manage_taxonomies` (`app/policies/admin/status_policy.rb` lines 26–28). It does not call `StatusPolicy#show?`. A projection id would return a body to a taxonomy admin.

`Admin::StatusPolicy#show?` (lines 14–16) is narrower: public, unlisted, reported, or already allowed by `StatusPolicy#show?`. An unreported personal status is hidden there. The trend actions do not use `show?`.

`BackupService` includes personal statuses in the ActivityPub outbox archive.

Staff who can read the database can read projections regardless of policy. That is the existing operator boundary. The application must still not put projection bodies on trend-review or export paths.

GAP. Admin trend approve/reject rejects projection ids. Backup skips them.

## Current behavior versus the proposal

| Today | Proposal |
| --- | --- |
| Personal is an account-owned visibility, and it is a real local status with an AP URI. | A projection may reuse a personal status row, but the URI stays null and `user_id` is the principal. |
| `PublishStatusService` skips AP distribute for personal and still link-crawls and webhooks. | Projection writer does not use that service. `store_uri` and both webhook callbacks return when the column is true or a marker exists. |
| `ActivityPub::DistributionWorker` will deliver personal if enqueued. | Worker skips projections and personal. |
| Delete of personal still reaches follower inboxes with a public-addressed Tombstone. `RemoveStatusService` discards before it destroys, and `destroy!` runs only when `permanently?`. | Projection removal is a physical `DELETE` in one transaction. It does not discard and does not call `remove_from_remote_reach`. Ordinary personal delete is unchanged until a separate issue. |
| Chewy indexes personal text. Favourite, Bookmark, and StatusStat call `update_index('statuses')` with no `search_indexable?` filter. The index scope includes every non-reblog. | Projections are outside the index scope because `external_projection` is true and because of the marker, and `delete_if` removes a loaded object. An import of the id after favourite, bookmark, or a full rebuild deletes or skips it. A missing marker does not put a true column back into the index. |
| Favourite and bookmark lists and destroys are account-scoped. Destroy of an existing row skips `authorize`. | Those responses require the projection's `user_id`. The other user of the account gets an empty list and a 404 destroy, and the row stays. |
| `purge_user!` runs before `purge_statuses!`. Discard does not cascade the marker. | Projection statuses are physically deleted in the same transaction, before the user row. `user_id` is `ON DELETE RESTRICT`. After commit, the user row is gone and no ActivityPub Delete was enqueued. Rollback leaves the status and the marker. |
| Indexes on `statuses(id, account_id)` are partial and not unique. A partial index on a new boolean would still scan `statuses` to build. | No new unique index on that pair, and no index on `external_projection`. The account match is an ordinary `BEFORE` row trigger. The boolean is read from the primary-key tuple. |
| Node user streams forward `timeline:{accountId}` with no visibility check (`streaming/index.js`). | P1 publishes no projection payload. A live owner channel is not claimed. |
| Self-boost is an `Announce` of the author's own status, with local feed dedup only. `reblog?` rejects direct and limited. A reblog cannot be `direct` (`status.rb` line 131). | Fediverse boost announces the owner's public, unlisted, or private reference Note. Share remains a single `Create`. Direct and limited are refused. |
| `PreviewCard` is global per URL. | Projections do not attach cards. Public reference Notes may, from a public fetch. |
| Favourite of a local status notifies the author and may register trends. | Projection favourite is local and does not register trends. Native like is opt-in. |
| Reblog of personal is already rejected. | Projection reblog, reply, and quote are rejected even if visibility is corrupted. |
| No external feed subscription model. | `external_subscriptions` plus shared `external_resources`. |
| Vault and registry exist for DeepL only. | Later providers add identity rows and vault classifications. No second secret store. |
| `ap_object_type` is note/page. | Unchanged. Source protocol is a column on the external tables. |
| Bridgy Fed display helper exists. | Not used to publish external bodies. Loop behavior is an experiment. |

## Privacy and abuse test matrix

Specs below are the P1–P6 acceptance tests. Paths are the files to extend or add. They do not exist for the bridge yet. Existing files cited here are real on the baseline.

Fail closed means: non-owner and unauthenticated callers get 404 for the projection id; no ActivityPub delivery job is enqueued; no other user's feed, notification, webhook, search hit, trend, or card gains the projection body; a raised error does not leave `state = succeeded`.

### A. Cross-user read and id guessing

| Case | Expect | Spec target |
| --- | --- | --- |
| Owner GET `/api/v1/statuses/:id` | 200, extension present, `visibility_ex` personal | `spec/controllers/api/v1/statuses_controller_spec.rb` |
| Second `users` row with the same `account_id` GETs that id, and loads `PersonalFeed`, `AccountStatusesFeed`, and `permitted_statuses_from_ids` | 404 or the id absent. `owned?` would have allowed it. The fixture inserts the second user in the database | statuses controller spec, `spec/controllers/api/v1/accounts/statuses_controller_spec.rb`, and a new personal-feed example |
| That second user GET `/api/v1/favourites`, `/api/v1/bookmarks`, and `/api/v1/emoji_reactions`, including `compact` | id absent | `spec/controllers/api/v1/favourites_controller_spec.rb`, `spec/controllers/api/v1/bookmarks_controller_spec.rb`, emoji reactions controller spec |
| That second user DELETE favourite and DELETE bookmark | 404, rows remain, no `UnfavouriteWorker`, body not rendered | `spec/controllers/api/v1/statuses/favourites_controller_spec.rb`, `spec/controllers/api/v1/statuses/bookmarks_controller_spec.rb` |
| That second user DELETE an emoji reaction on the projection | 404, the reaction row stays, body not rendered | new example next to `app/controllers/api/v1/statuses/emoji_reactions_controller.rb` |
| `UnfavouriteWorker` with only `account_id` | projection favourite remains, body not serialized | `spec/workers/unfavourite_worker_spec.rb` or a new example next to the worker |
| Caller with the matching account and `viewer_user_id` nil | id absent. Background and backup paths included | writer spec and `spec/services/backup_service_spec.rb` |
| Other local user GET same id | 404 | statuses controller spec |
| Unauthenticated GET, HTML permalink, oEmbed | 404 | `spec/controllers/statuses_controller_spec.rb`, `spec/controllers/api/oembed_controller_spec.rb` |
| Other user's home, list, public, tag, account statuses, and AP outbox | id absent | `spec/services/fan_out_on_write_service_spec.rb`, `spec/controllers/api/v1/accounts/statuses_controller_spec.rb`, `spec/controllers/activitypub/outboxes_controller_spec.rb` |
| Redis `timeline:public` and the other account's `timeline:{id}` | no publish of the projection id. Node is not relied on to drop it | fan-out spec. Subscription behavior is `streaming/index.js`, cited above |
| Context of an unrelated status | projection absent | statuses controller spec |
| Favourited-by and reblogged-by | 404 for non-owner | `spec/controllers/api/v1/statuses/favourited_by_accounts_controller_spec.rb` and the reblogged-by spec |
| Search `in:all` and a raw Chewy document | no projection document | `spec/controllers/api/v2/search_controller_spec.rb`, `spec/models/status_searchable_text_spec.rb` |
| Admin trend approve on the id | 404, `trendable` unchanged | new example next to admin trends controller coverage |
| Backup outbox | projection id absent | `spec/services/backup_service_spec.rb` |
| Mention row inserted directly | still 404 for the mentioned user | policy spec `spec/policies/status_policy_spec.rb` |

### B. ActivityPub dereference and feeds

| Case | Expect | Spec target |
| --- | --- | --- |
| Marker insert raises inside the writer transaction | no status row, no marker, no webhook job, no Chewy document | new projection writer spec |
| Both rows commit | `uri` null, no webhook, raw Chewy get absent after refresh, no Redis publish | same |
| Create, favourite, bookmark, unfavourite, unbookmark, refresh after each | raw Chewy document absent after every refresh | new index spec |
| Full `StatusesIndex` import of the scope | projection id still absent | index spec |
| Document planted, then marker commit and post-commit import | document gone | index spec |
| Projection `uri` is null after create | column null | same |
| `ActivityPub::DistributionWorker` given the id | no `DeliveryWorker` | `spec/workers/activitypub/distribution_worker_spec.rb` |
| Update worker and `UpdateStatusService` | refused or no delivery | `spec/workers/activitypub/status_update_distribution_worker_spec.rb` |
| `RemoveStatusService` on the projection | no remote Delete, no follower inbox | `spec/services/remove_status_service_spec.rb` |
| Reference Note create | `Create` actor is the Fedibird user; object id is the reference URI; body matches the template and does not include the fixture article body | new reference spec |
| Boost when a reference Note already exists | one `Announce` of that Note's URI, no second `Create` | reference spec, plus `spec/services/reblog_service_spec.rb` |
| Boost when it does not exist | confirm required; then one `Create` and one `Announce`; unreblog sends Undo and leaves the Note | reference spec |
| Boost of the projection id or of the external URL | no `Announce` | reference spec |
| Boost of a direct or limited reference Note, and a boost requested as direct or limited | refusal from `reblog?` or the visibility validation. No wrapper, no `Announce` | `spec/services/reblog_service_spec.rb` |
| Reference delete | Delete refers to the reference URI only. Reblogs of that Note are removed. The projection remains | remove-status spec |
| Outbox and profile RSS | reference appears according to its visibility; projection does not | outboxes spec, accounts controller |

### C. Interactions

| Case | Expect | Spec target |
| --- | --- | --- |
| Owner favourite and bookmark | local rows, no delivery, no trend register | `spec/services/favourite_service_spec.rb`, bookmarks controller spec |
| Non-owner favourite | 404, no row | favourites controller spec |
| Ordinary reply, reblog, quote, emoji reaction | 422, no new status | `spec/services/reblog_service_spec.rb`, post-status spec |
| Native like without identity | `external_identity_required`, no succeeded activity | new `spec/services/external_bridge/activities_spec.rb` |
| Native like with revoked credential | `credential_revoked`, vault `with_credential` not yielding | same, plus vault spec style |
| Retry after a lost 200 | no second `createRecord` until reconcile; adopted URI if the record exists; `remote_state` stays `unknown` until then | activities spec |
| Like, unlike, like | one row; unlike deletes the stored `native_activity_uri`; the next like uses a new rkey | activities spec |
| Two users submit the same idempotency string | two command rows. Uniqueness is `(user, identity, key)` | activities spec |
| Replay the like key after unlike | `superseded`, `desired` stays inactive, no second `createRecord` | activities spec |
| New key carrying the like's `expected_generation` after unlike | `stale_activity_command`, no PDS write | activities spec |
| New key whose `expected_generation` is the current generation | accepted, generation increments, new rkey on the next like | activities spec |
| Concurrent double click | one PDS write | activities spec |
| Native failure after local favourite | local row remains, `remote_state` is not `present`, and the same request does not send a compensating `deleteRecord` | activities spec |
| 401 from the resolved PDS after the write may have left | stop, `remote_state` stays `unknown`, no retry against another host | activities spec |
| Inbound sync | rows in `inbound_interactions` only. Zero new `Notification` or `Account` | new inbound spec |

### D. Shared cache and trends

| Case | Expect | Spec target |
| --- | --- | --- |
| Two users, one public feed fixture | one `external_resources` row, two projections, no `user_id` on the resource | new fetch spec |
| Authenticated fixture, 401, and a redirect onto a private address | no `external_sources` row, no `external_resources` row, no public cache key, no ETag stored. Caller receives `authenticated_source_rejected` or the SSRF error | fetch spec |
| User B fetches after user A's rejected private URL | still no shared row | fetch spec |
| Previously public source later returns 401 | shared ETag unchanged; that user's subscription `error`; other users' public copies unchanged | fetch spec |
| Projection text contains a URL | no `PreviewCard`, no `LinkCrawlWorker` | `spec/services/fetch_link_card_service_spec.rb` |
| Public reference with the same URL | card allowed; trend register only if the reference is public | `spec/services/fetch_link_card_trend_metadata_spec.rb` |
| Private favourite | `Trends::Statuses` score unchanged | trends model spec |
| Snapshot counts | not added to `status_stat` | snapshot spec |

### E. Loops, promotion, deletion

| Case | Expect | Spec target |
| --- | --- | --- |
| Same URL or same title, different guid / AT URI | two resources | identity spec |
| RSS item without guid and without link | skipped, no projection | fetch spec |
| New CID, same AT URI | same resource id, new revision, no AP Update | identity spec. Parser behavior is UNVERIFIED until P2 uses a real AT URI parser |
| Attempt to change projection visibility to public | refused, `uri` still null | writer spec |
| User delete through the service | one transaction. After commit the user row, the status row, and the marker are gone. No `DeliveryWorker` and no `RemovalWorker`. The other user of the account keeps their own projections. Shared resource remains | account deletion spec |
| `DELETE FROM users` while a marker remains, and `Account#destroy` while a marker remains | raises. Status, marker, and user stay | account deletion spec |
| User-delete service raises after the status `DELETE` is issued | rollback. Status, marker, and user are all still there. `uri` is null | account deletion spec |
| `Status#discard` or `RemoveStatusService` on a projection | not success. Marker remains, so a following user delete raises. No adopted path delivers ActivityPub Delete | `spec/services/remove_status_service_spec.rb` |
| Direct `DELETE` of the marker while the status exists | rejected by the ordinary `BEFORE DELETE` trigger. `external_projection` stays true. The status is not-found and is not indexed | writer spec |
| `pg_trigger` for the account-match trigger | non-constraint, `BEFORE`, `FOR EACH ROW`. An update of marker `user_id`, `account_id`, or `status_id` raises. An update of `statuses.account_id` or `users.account_id` while a marker exists raises | writer spec |
| Marker gone, column still true | not-found for every caller, including the former owner, on REST, HTML, ActivityPub, and oEmbed. `store_uri` leaves `uri` null. Create and update webhooks do not enqueue. `DistributionWorker` does not deliver. No federated Delete. Chewy document absent. Repair is a physical `DELETE` of the status and does not clear the column | writer spec, `spec/controllers/api/v1/statuses_controller_spec.rb`, `spec/controllers/statuses_controller_spec.rb`, `spec/workers/activitypub/distribution_worker_spec.rb` |
| Insert projection with a mismatched subscription user, status account, or resource source | the `BEFORE` row trigger or a foreign key rejects the statement; the writer transaction leaves no status | writer spec |
| P5 group member from similar text or URL, or from a like record | no member. An explicit AT URI whose DID matches the identity can be added | publication-group spec |
| Identity disconnect | inbound rows gone; outbound rows deleted only when `absent` or `pending_create` with no request sent; `present` and `unknown` rows remain without a token; public projections remain; vault row revoked | identity spec |
| Bridgy Fed or another bridge observing a reference Note | UNVERIFIED experiment, required before the P6 flag can be turned on. Record the remote result in the P6 issue | manual experiment notes, not a unit stub presented as proof |

### F. SSRF, XML, and secrets

| Case | Expect | Spec target |
| --- | --- | --- |
| Feed URL to a literal private address, and a redirect to one | `Mastodon::PrivateNetworkAddressError` or host validation error, no row | fetch spec using `Request` |
| Userinfo or token query in the feed URL | rejected, no shared row, secret not stored | fetch spec |
| Followers-only parent, then a public reply | new public parent after confirm; the followers-only parent stays followers-only | reference spec |
| Public parent, then a followers-only reply | reuses the public parent; no second parent | reference spec |
| Two concurrent parent creates at the same scope | one Note and one `Create` | reference spec |
| Parent deleted, then another reply | confirm a new parent; old replies are not retargeted | reference spec |
| Visibility edit of an auxiliary parent | refused | reference spec |
| XXE / external entity in fixture XML | entity not fetched | fetch spec |
| Job payload and log lines for a failed fetch | no token, no ciphertext, no `encrypted_payload` | activities spec and vault spec |
| Generic `POST /settings/external_services/:provider` | route absent | routes spec |

## Rollout checks before a flag may be enabled

P1 `external_bridge_rss` stays off until section A, the projection rows of section B (null `uri`, no distribution, no delete reach, no Redis publish, Chewy absent through favourite and a full import), the local interaction refusals in section C, and sections D and F are green. The two-users rows, the favourite, bookmark, and emoji-reaction list and destroy rows, the user-delete, rollback, discard, and marker-delete rows, the flag-without-marker entrypoints, and the mismatch inserts are part of that gate. The parent-scope rows in F are P6 specs; they do not block the RSS flag. The transaction rollback rows in B do. The migration adds `external_projection` with no default and does not add an index on it. It does not add a unique index on `statuses(id, account_id)`. The account-match trigger is an ordinary `BEFORE` row trigger.

P3 stays off until the native rows of section C are green, including lost-ack reconcile, the command-key uniqueness, and the stale-replay rows.

P4 stays off until the inbound row of section C is green.

P5 stays off until the publication-group row in section E is green. That phase does not add `create_post`.

P6 stays off until section B's reference and boost rows are green, including the direct and limited refusal, and the experiments in section E are recorded for both `Create` and `Announce`. A passing unit test that stubs the remote server does not replace that experiment.

## Unverified items that must not be described as done

- Remote server reaction to today's personal-status Delete.
- Bridgy Fed, or any other bridge, looping on a link-only Note.
- Whether a future owner Redis channel would stay limited to that socket. The current Node paths are cited above and do not perform that check. P1 publishes no projection payload.
- AT URI parsing, CID replacement, and PDS session behavior. No client is in the tree.
- X and mixi2 API availability and terms.
- Whether a stock client can be taught the `fedibird_external` extension. The server contract does not depend on that.
