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

GAP. `store_uri`, `search_indexable?`, and webhook callbacks must no-op when a projection row exists. `permitted_for`'s mention branch must not return a projection to other users.

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

UNVERIFIED. Node streaming subscription auth. This repo publishes to Redis; the Node process was not re-reviewed line by line in this pass. Ruby `PushUpdateWorker` is covered below.

## Timelines, Redis, streaming, search

CONFIRMED.

`FanOutOnWriteService#call` (`app/services/fan_out_on_write_service.rb`):

- Returns immediately for `ap_page?` (line 17).
- Delivers to self unless the status is direct and the user hides direct (line 23). That self delivery runs **before** the personal branch.
- Personal then delivers to self-included lists unless `setting_hide_personal_from_timeline`, and returns (lines 25–27). No follower, public, hashtag, or media firehose delivery.

`Feed#filtered_scope` (`app/models/feed.rb` lines 78–83) loads status ids and optionally filters a visibility list. It does not call `StatusPolicy`.

`PushUpdateWorker#perform` (`app/workers/push_update_worker.rb` lines 7–14) loads the status and renders it to `timeline:{account}` with no policy check.

`StatusesIndex` stores `searchable_by` and `searchability` (`app/chewy/statuses_index.rb` lines 215–216). Personal text is indexed because `search_indexable?` allows it. `SearchQueryTransformer` can restrict queries to `searchable_by` of the current account. That is a query filter, not an index-time exclusion.

`PublishStatusService` (`app/services/publish_status_service.rb`):

- Skips mention delivery for personal (lines 48–50).
- Always enqueues `DistributionWorker` (lines 54–59).
- Skips `ActivityPub::DistributionWorker` for personal (line 61).
- Always enqueues `LinkCrawlWorker` (lines 64–67).

RISK. A projection published through `PostStatusService` lands on the owner's home Redis feed and streaming channel, is link-crawled, and is indexed. If its id is ever written into another account's feed ZSET, `Feed#filtered_scope` will render it. If visibility is anything but personal, follower and public fan-out run.

GAP. The projection writer must not call `PublishStatusService`. Index and link-crawl hooks must skip the marker even if a later bug calls them. Feed reads must drop projection ids for every account except the owner.

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
| `ReblogService` | 41–50 | Rejects `personal`. Otherwise creates a status and enqueues both distribution workers with no further personal check. |
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

GAP. P1 stores text on the projection and the shared public resource only. It does not download media. Authenticated bodies use `external_private_blobs` and the `v1:external_private/...` key. Deletion of a projection does not deliver ActivityPub and does not delete the shared public resource.

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
| `PublishStatusService` skips AP distribute for personal and still link-crawls and webhooks. | Projection writer does not use that service. Callbacks also check the marker. |
| `ActivityPub::DistributionWorker` will deliver personal if enqueued. | Worker skips projections and personal. |
| Delete of personal still reaches follower inboxes with a public-addressed Tombstone. | Projection removal does not call `remove_from_remote_reach`. Ordinary personal delete is unchanged until a separate issue. |
| Chewy indexes personal text. | Projections are not indexed. |
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
| Other local user GET same id | 404 | same |
| Unauthenticated GET, HTML permalink, oEmbed | 404 | `spec/controllers/statuses_controller_spec.rb`, `spec/controllers/api/oembed_controller_spec.rb` |
| Other user's home, list, public, tag, account statuses, and AP outbox | id absent | `spec/services/fan_out_on_write_service_spec.rb`, `spec/controllers/api/v1/accounts/statuses_controller_spec.rb`, `spec/controllers/activitypub/outboxes_controller_spec.rb` |
| Context of an unrelated status | projection absent | statuses controller spec |
| Favourited-by and reblogged-by | 404 for non-owner | `spec/controllers/api/v1/statuses/favourited_by_accounts_controller_spec.rb` and the reblogged-by spec |
| Search `in:all` and a raw Chewy document | no projection document | `spec/controllers/api/v2/search_controller_spec.rb`, `spec/models/status_searchable_text_spec.rb` |
| Admin trend approve on the id | 404, `trendable` unchanged | new example next to admin trends controller coverage |
| Backup outbox | projection id absent | `spec/services/backup_service_spec.rb` |
| Mention row inserted directly | still 404 for the mentioned user | policy spec `spec/policies/status_policy_spec.rb` |

### B. ActivityPub dereference and feeds

| Case | Expect | Spec target |
| --- | --- | --- |
| Projection `uri` is null after create | column null | new projection writer spec |
| `ActivityPub::DistributionWorker` given the id | no `DeliveryWorker` | `spec/workers/activitypub/distribution_worker_spec.rb` |
| Update worker and `UpdateStatusService` | refused or no delivery | `spec/workers/activitypub/status_update_distribution_worker_spec.rb` |
| `RemoveStatusService` on the projection | no remote Delete, no follower inbox | `spec/services/remove_status_service_spec.rb` |
| Reference Note create | `Create` actor is the Fedibird user; object id is the reference URI; body matches the template and does not include the fixture article body | new reference spec |
| Reference delete | Delete refers to the reference URI only | remove-status spec |
| Outbox and profile RSS | reference appears according to its visibility; projection does not | outboxes spec, accounts controller |

### C. Interactions

| Case | Expect | Spec target |
| --- | --- | --- |
| Owner favourite and bookmark | local rows, no delivery, no trend register | `spec/services/favourite_service_spec.rb`, bookmarks controller spec |
| Non-owner favourite | 404, no row | favourites controller spec |
| Ordinary reply, reblog, quote, emoji reaction | 422, no new status | `spec/services/reblog_service_spec.rb`, post-status spec |
| Native like without identity | `external_identity_required`, no succeeded activity | new `spec/services/external_bridge/activities_spec.rb` |
| Native like with revoked credential | `credential_revoked`, vault `with_credential` not yielding | same, plus vault spec style |
| Retry of the same idempotency key | one provider call | activities spec |
| Native failure after local favourite | local row remains, activity `failed` | activities spec |
| Inbound sync | rows in `inbound_interactions` only. Zero new `Notification` or `Account` | new inbound spec |

### D. Shared cache and trends

| Case | Expect | Spec target |
| --- | --- | --- |
| Two users, one public feed fixture | one `external_resources` row, two projections, no `user_id` on the resource | new fetch spec |
| Authenticated fixture | body only in `external_private_blobs` for that user and binding | fetch spec |
| Replaced credential (new binding) | old private blob not readable | fetch spec |
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
| User delete | projections, subscriptions, identities, private blobs gone; shared resource remains; no AP Delete for the projection | account deletion spec |
| Identity disconnect | inbound and pending activities for that identity gone; public projections remain; vault row revoked | identity spec |
| Bridgy Fed or another bridge observing a reference Note | UNVERIFIED experiment, required before the P6 flag can be turned on. Record the remote result in the P6 issue | manual experiment notes, not a unit stub presented as proof |

### F. SSRF, XML, and secrets

| Case | Expect | Spec target |
| --- | --- | --- |
| Feed URL to a literal private address, and a redirect to one | `Mastodon::PrivateNetworkAddressError` or host validation error, no row | fetch spec using `Request` |
| Userinfo or token query in the feed URL | rejected or stored only as an authenticated fetch with the secret in the vault, never in `canonical_key` | fetch spec |
| XXE / external entity in fixture XML | entity not fetched | fetch spec |
| Job payload and log lines for a failed fetch | no token, no ciphertext, no `encrypted_payload` | activities spec and vault spec |
| Generic `POST /settings/external_services/:provider` | route absent | routes spec |

## Rollout checks before a flag may be enabled

P1 `external_bridge_rss` stays off until section A, the ActivityPub rows of section B, the local interaction refusals in section C, and sections D and F are green on that change.

P3 stays off until the native rows of section C are green.

P4 stays off until the inbound row of section C is green.

P6 stays off until section B's reference rows are green and the Bridgy Fed experiment in section E is recorded. A passing unit test that stubs the remote server does not replace that experiment.

## Unverified items that must not be described as done

- Remote server reaction to today's personal-status Delete.
- Bridgy Fed, or any other bridge, looping on a link-only Note.
- Node streaming source filters beyond the Ruby publisher.
- AT URI parsing, CID replacement, and PDS session behavior. No client is in the tree.
- X and mixi2 API availability and terms.
- Whether a stock client can be taught the `fedibird_external` extension. The server contract does not depend on that.
