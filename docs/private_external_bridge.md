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
2. **Shared fetch, never shared social state.** Public source bytes may be fetched once and cached. Credentials, subscription membership, read state, annotations, and interactions are stored per user. An authenticated response is never written into the shared cache.
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
| Auxiliary parent | The single AP reference reused as `inReplyTo` / quote target for later federation. Distinct from a standalone share. |

## Three records, three audiences

```text
public fetch                         owner only                         owner's real actor
─────────────────────────            ─────────────────────────          ─────────────────────────
external_sources                     external_subscriptions             external_ap_references
external_resources                   external_status_projections        statuses row (real Note)
external_actors                      favourites / bookmarks             ActivityPub Create
(no user_id, no token)               inbound_interactions               canonical URL + label
                                     external_activities
                                     publication_groups

        │                                    │                                    │
        │  copy public fields into           │  never used as an AP object id    │  never points at the
        └──────── the projection ────────────┴────────────────────────────────────┘  projection row
```

The shared side answers "what is this public object?" The owner side answers "what did this user do with it?" The ActivityPub side answers "what did this Fedibird account choose to publish?"

A second user fetching the same public feed reads the same `external_resources` row and writes a different projection. Their favourite does not increment the first user's `status_stat`, and it does not increment a column on `external_resources`.

## Why the projection is not a synthetic account

`StatusPolicy#owned?` is `author.id == current_account&.id` (`app/policies/status_policy.rb`). A shared synthetic account would make every projection on that account visible to anyone acting as that account, and a per-user synthetic account would be a local actor: `Account#local?` is `domain.nil?`, local actors are Webfinger-discoverable, and `FanOutOnWriteService` calls `status.account.user` while delivering. `users.account_id` is indexed and is not unique (`db/schema.rb`, `index_users_on_account_id`).

The projection status therefore uses the **owner's real local account** as `statuses.account_id`. The privacy principal is `external_status_projections.user_id`, which must equal that account's user. Guards compare `user_id`. They do not stop at `owned?`.

External authors are `external_actors` rows. They are not followable, not Webfinger subjects, and not `Account.protocol` values. `Account.protocol` remains `ostatus` or `activitypub`. There is no `statuses.protocol`. `ap_object_type` remains `note` or a future `page` and is not reused.

Stock Mastodon clients will show the owner's account on the projection, because that is `status.account`. That mis-attribution stays on the owner's own sessions: the projection is never federated. The Fedibird client reads the owner-only `fedibird_external` extension below. Creating a phantom actor so that stock clients show the external display name is out of scope. This is a review decision; the default is no phantom actor.

## Projection status contract

P1 may insert a `statuses` row so `/api/v1/statuses/:id` and existing favourite/bookmark clients keep working. The row is legal only when all of the following hold:

- `external_status_projections.status_id` points at it, unique, and `user_id` is the owner.
- `visibility` is `personal` and `searchability` is `personal`.
- `uri` is null. `Status#local?` is true when `uri` is null, which is acceptable only because the fail-closed list below treats the projection marker as stronger than `local?`.
- `text` may contain the owner's private copy of public source text. That text is not an ActivityPub `content` value.
- No `MediaAttachment`, no `PreviewCard` join, no poll, no mention rows, no hashtag rows.
- `in_reply_to_id`, `reblog_of_id`, and `quote_id` are null.
- The writer does not call `PostStatusService`, `PublishStatusService`, `ReblogService`, or `RemovalWorker`.

No new column is added to `statuses` in the first migration. PostgreSQL can add a nullable column without rewriting the table, but every status row is hot, and the marker fits in a side table. The callback probe is a unique-index lookup on `external_status_projections.status_id`. If that probe shows up in production profiles, a later migration may add a nullable `statuses.external_projection` with no default and a partial index. That migration is not part of P0 and is not required to start P1.

`visibility = personal` still matters as defense in depth, because current fan-out already special-cases it. It is not the boundary. The audit lists paths that ignore it (`ActivityPub::DistributionWorker`, webhooks, Chewy, link crawl, delete reach).

### Fail-closed list

Any path that loads a status id must treat "a projection row exists" as private, even if `visibility` was edited. Before the first projection is written, these paths gain an explicit skip or refusal. The audit names the current symbols.

| Path | Required behavior |
| --- | --- |
| `Status#store_uri` | Do not set `uri`. |
| `ActivityPub::TagManager#uri_for` / `#url_for` | Do not build an account status URL for a projection. Callers serialize nothing. |
| `PublishStatusService` and `ActivityPub::DistributionWorker` | Do not enqueue. The worker also skips projections itself, including `personal`, which it does not skip today. |
| `FanOutOnWriteService`, `PushUpdateWorker` | Do not insert or render a projection except an owner-scoped read model that does not publish to `timeline:` channels for other accounts. |
| `trigger_create_webhooks` / `trigger_update_webhooks` | Do not enqueue. |
| `search_indexable?` / `StatusesIndex` | Do not index the projection. Personal posts are indexed today; projections must not be. |
| `FetchLinkCardService` / `LinkCrawlWorker` | Do not run. |
| `RemoveStatusService#remove_from_remote_reach` | Do not deliver Delete or Undo. |
| `BackupService` outbox export | Skip projection ids. A backup must not turn the private text into an ActivityPub Note. |
| `ReblogService`, quote, `PostStatusService` reply, `ProcessStatusReferenceService` | Refuse the projection as a target. |
| `FavouriteService` / bookmarks / emoji reactions | Local row only, and only for the owner. No `ActivityPub::DeliveryWorker`, no trend registration, no notification to anyone but the owner. |
| REST, HTML, oEmbed, RSS, ActivityPub show, outbox, search, trends, streaming, admin trend review | Non-owners receive the same not-found they get for a status they cannot see. Unauthenticated callers receive not-found. |
| `Status.permitted_for` | A mention row must not make a projection visible. Projections do not create mentions. The scope also excludes projection ids for every viewer except the owning user. |

Ordinary `personal` posts keep today's behavior. The new condition is the projection marker, not a change to personal-post federation. One current behavior is called out because P1 must not inherit it: deleting a local personal status still builds follower inboxes in `StatusReachFinder` (`unsafe: true` disables the direct/limited early return) and `ActivityPub::DeleteSerializer#to` addresses Public. Projection deletion must not call that path. Changing delete reach for ordinary personal posts is a separate bugfix, not this bridge.

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

### Auxiliary parent versus standalone share

| User action | Record | ActivityPub effect |
| --- | --- | --- |
| Share a link to the Fediverse | New reference Note every time (`kind = standalone_share`) | One `Create` at the chosen visibility. Not an `Announce`. |
| Reply or quote on the Fediverse | Reuse one auxiliary parent per `(user, resource)` (`kind = auxiliary_parent`), then a second status whose `in_reply_to_id` or `quote_id` is that parent | `Create` of the parent if it did not exist, then `Create` of the reply or quote. |
| Boost on the Fediverse | Same as share: `Create` the reference Note. Do not `Announce` the projection or the external URL. | A later boost of that Note is an ordinary boost of the user's own post. |
| Reply or like on the native service | `external_activities` only | No ActivityPub activity. |

Creating an auxiliary parent publishes that parent to its audience. The confirm step says so before the parent is created. A native reply does not create a parent.

The reply's ActivityPub `inReplyTo` is the auxiliary parent's local URI. It is not the external URL, not the AT URI, and not the projection. Remote servers may still notice the URL inside the text. Whether Bridgy Fed or another bridge will fetch that URL and post back is **not established**. P6 does not ship until an experiment records the result. Mitigations that are in this design anyway: the object id is the local status URI, the actor is the Fedibird user, and nothing sets the external author as `attributedTo`.

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
- reject userinfo. A username or password in the URL is not stored. The user must use a vault credential, and that feed is then authenticated rather than shared.

If the query contains `token`, `key`, `sig`, `signature`, or `access_token`, the fetch is authenticated even when the response was reachable. It is not written to `external_resources`.

Item key, first match:

1. RSS `guid` or Atom `id`, trimmed and non-empty, scoped to the source key.
2. Else the entry link URL, normalized the same way, scoped to the source key.

Entries with neither are skipped. A content hash is not an identity. The same guid on two feeds is two resources. A byline string is display text, not an actor id. The feed's `external_actors` key is the source key.

### AT Protocol

Resource key: the AT URI `at://<did>/<collection>/<rkey>`, parsed as an AT URI. This document does not treat a regex as a parser. The DID is case-sensitive. The handle is not the key.

Revision: the CID. A new CID at the same AT URI updates the shared row's revision and digest. It does not insert a second resource and does not emit an ActivityPub `Update`. Each projection stores `last_seen_revision` so the owner can see that the source changed. The public reference Note is left unchanged unless the user explicitly publishes again, which creates a new standalone share rather than editing the old one in place.

A missing public record sets `source_deleted_at` on the shared row. That is a public observation. It does not delete other users' projections. Each projection hides or keeps the last public copy under the owner's local retention choice. P1's choice is: keep the projection text, mark it source-deleted, and do not refetch it into the shared body.

Native like and repost records have their own AT URIs. Those URIs are `external_activities.native_activity_id`, not the subject resource key.

Authenticated or follower-only records are not shared. They use `external_private_blobs`.

### URL canonicalization limits

Redirects can collapse two user-entered URLs onto one source. That merge is allowed for the shared public source and forbidden for subscriptions: each user keeps their own subscription row. Private query tokens must be stripped before any shared key is computed. If a token cannot be stripped with confidence, the URL is rejected.

## Cache keys

Public material, no credential on the request:

```text
v1:external_public/<protocol>/<sha256(canonical_key)>/<revision>
```

Authenticated material:

```text
v1:external_private/user/<user_id>/credential/<credential_id>/binding/<binding_id>/<protocol>/<sha256(canonical_key)>/<revision>
```

The digest input is the canonical key after secrets are removed. The key does not contain the token, the API password, or a raw URL that still has a userinfo or token query. This matches the Personal DeepL partition (`user` / `credential` / `binding`) and does not reuse `v3:translations/...`.

Public cache entries may be reused across users. Private cache entries are deleted when the credential is replaced (the binding id changes), revoked, or the user is deleted. A shared entry stores no `user_id`.

Caps, required before P1 writes a body: at most 1 MiB of stored text, a recorded `truncated` flag, and a response byte limit on the HTTP client. XML parsers for RSS must disable network entity resolution. The HTTP client is the existing `Request` class, which rejects private addresses, not a new open client.

Job arguments are `owner_user_id`, `subscription_id` or `resource_id`, `credential_id`, `provider`, `purpose`, and `credential_type`. The worker reloads rows and calls `with_credential`. It does not receive a URL and a secret together.

## Data model

Names are the contract for later migrations. P0 does not add them. Types are the intended PostgreSQL shape.

Shared tables have **no** `user_id`. Owner tables are `NOT NULL user_id` with `ON DELETE CASCADE` to `users`.

### `external_sources`

| Column | Constraint |
| --- | --- |
| `id` | primary key |
| `protocol` | `rss`, `atom`, `atproto` in the phases below. `x` and `mixi2` are reserved and unused until a terms review |
| `canonical_key` | not null |
| `fetch_class` | `public` or `authenticated` |
| `etag`, `last_modified`, `fetched_at`, `http_status` | nullable |
| `title`, `site_url` | nullable public metadata |

Unique `(protocol, canonical_key)`. No subscriber count column.

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
| `title`, `body`, `body_digest` | public fetched text only. Null when `fetch_class` would have been authenticated |
| `published_at`, `source_deleted_at`, `truncated` | |
| `fetched_at` | |

Unique `(protocol, canonical_key)`. Index `(external_source_id, published_at)`.

### `external_private_blobs`

Owner-scoped body for an authenticated fetch. Unique `(user_id, credential_id, binding_id, canonical_key_digest)`. `ON DELETE CASCADE` from `users`. No foreign key into `external_resources.body`. Replaced bindings orphan old blobs; a revocation job deletes them.

### `external_subscriptions`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_source_id` | not null |
| `credential_id` | nullable FK to `user_external_credentials`. Null for public RSS |
| `state` | `active`, `paused`, `error` |
| `last_error_code` | nullable class or provider code. No response body and no token |

Unique `(user_id, external_source_id)`.

### `external_status_projections`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_subscription_id` | not null |
| `external_resource_id` | not null |
| `status_id` | not null, unique, FK to `statuses` `ON DELETE CASCADE` |
| `last_seen_revision` | nullable |
| `source_deleted` | boolean, default false |

Unique `(user_id, external_resource_id)`.

Deleting the user deletes the account through the existing account-deletion flow, which deletes statuses. The projection row then disappears via `status_id` cascade. Account deletion must use the non-federating removal path for any status that still has a projection row. `user_id` cascade covers projection rows if the status is already gone.

### `external_identities`

The connection metadata model required by `docs/external_services.md` when a provider needs host, subject, handle, scopes, or expiry. Not a JSON column on `user_external_credentials`.

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `provider` | registry key, for example `bluesky` |
| `subject` | stable remote subject, the DID for AT Protocol |
| `handle`, `display_name` | nullable |
| `credential_id` | nullable FK. The vault row's `provider`, `purpose`, and `credential_type` are fixed by that provider's controller |
| `scopes` | text array of granted capabilities, not a free-form token scope dump of secrets |
| `disconnected_at` | nullable |
| `terms_state` | `unreviewed`, `approved`, `rejected`. X and mixi2 stay `unreviewed` |

Unique `(user_id, provider, subject)`.

`PostingIdentity::KNOWN_KINDS` already names `bluesky`, and `ENABLED_KINDS` is only `local`. This bridge does not enable that kind. A native identity is not a Fedibird posting sender. The ActivityPub actor remains the local account.

Suggested vault classification for a later Bluesky issue, not created here:

```text
provider        = bluesky
purpose         = identity
credential_type = (chosen in that issue: oauth refresh token or app password)
```

The browser cannot choose those values. There is no `POST /settings/external_services/:provider`.

### `external_activities`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_identity_id` | not null |
| `external_resource_id` | nullable for replies that target a native post |
| `external_status_projection_id` | nullable |
| `action` | `like`, `unlike`, `repost`, `unrepost`, `reply` |
| `idempotency_key` | not null, unique |
| `state` | `pending`, `succeeded`, `failed`, `undone` |
| `native_activity_id` | nullable until the provider accepts |
| `attempt_count`, `last_error_code` | no token, no raw body |
| `local_favourite_id`, `local_status_id` | nullable links to local rows when the user also asked for a local effect |

Partial unique index: one row in `pending` or `succeeded` per `(user_id, external_identity_id, external_resource_id, action)` for `like` and `repost`. Replies use the client idempotency key only, so several replies can exist.

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

A group exists only when the user completes an explicit crosspost. Members are either a `local_status_id` or a `(protocol, native_object_id)` already known from an `external_activity`. Unique member identity inside the group. Text or URL similarity must not insert a member.

### `external_ap_references`

| Column | Constraint |
| --- | --- |
| `user_id` | not null, cascade |
| `external_resource_id` | not null |
| `status_id` | not null, unique, the reference Note |
| `kind` | `auxiliary_parent` or `standalone_share` |

Partial unique index on `(user_id, external_resource_id)` where `kind = auxiliary_parent`. Standalone shares are not unique. Deleting the Note deletes the reference row. It does not delete the projection.

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

Authenticated calls use a fixed endpoint table in the provider class. Bluesky's first slice uses server-configured hosts (the public AppView and the official session host). A user-supplied PDS URL is not accepted, because the vault forbids a credential plus an arbitrary URL. Custom PDS support is a later review.

Public RSS fetches use `Request` with no vault access. They still have a per-host rate limit and a response size limit. Authenticated fetches have a per-user budget as well.

Sudo matches the external-services pages: mutation routes require a recent challenge, secrets never enter the challenge, the flash, or the redirect. There is no credential REST API.

## Consent and ordinary API clients

| Action | Default for an ordinary Mastodon client | What the Fedibird UI can add |
| --- | --- | --- |
| Read a projection | Owner-only GET of the status id | External byline from `fedibird_external` |
| Favourite / unfavourite | Local favourite only | Separate control: also like on the connected identity |
| Bookmark | Local bookmark only. Bookmarks are already local | None |
| Reply | **422**. A normal reply would be a real status pointing at the projection | Two controls: "Reply on Fediverse" (reference flow) and "Reply on Bluesky" (native) |
| Boost | **422**. `ReblogService` already rejects `personal`, and the projection marker is a second refusal | "Share to Fediverse" runs the reference flow |
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
| Native side | None for public RSS. AT read of non-public records uses the identity credential against the fixed endpoint. |
| ActivityPub | None. |
| Consent | The user adds the source. Public RSS needs no remote account. |
| Idempotency | Unique `(user, source)` and `(user, resource)`. A refetch updates `last_seen_revision` in place. |
| Failure | Subscription `error` with a code. Partial item failure skips that item and continues. No projection is left without its marker row: status and marker commit in one transaction. |
| No identity | Public RSS succeeds. Authenticated sources fail with `external_identity_required`. |
| Revoked credential | Authenticated fetch fails closed. Existing public projections stay. Private blobs are not served. |

### Favourite / unfavourite

| | |
| --- | --- |
| Local effect | `Favourite` on the projection status for the owner. Unfavourite destroys that row. `status_stat.favourites_count` changes only on that status. |
| Native side | None unless the user opted in. Opt-in writes `external_activities` (`like` / `unlike`) and calls the provider. |
| ActivityPub | None. The author account is the owner's own account, so today's `FavouriteService` would notify the owner. The projection path must not fan that notification out as if a third party acted, and must not call `Trends.statuses.register`. |
| Consent | Local favourite needs no extra consent. Native like needs a connected capability and an explicit opt-in. |
| Idempotency | Local `find_or_create` by `(account, status)`. Native partial unique index on the open like. Retries reuse `idempotency_key`. |
| Failure | Native failure leaves `state = failed` and does not roll back the local favourite if the user asked for both. The UI shows the native failure. A native-only request that fails creates no local favourite. |
| No identity / revoked | Local favourite still works. Native opt-in returns `external_identity_required` or `credential_revoked` and does not create a succeeded activity. |

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
| Local effect | Fediverse reply: auxiliary parent plus a new status by the user, `in_reply_to` the parent, not the projection. Native reply: an `external_activities` row of `action = reply`, optional local note only if the user also composed a Fediverse reply. |
| Native side | Native reply posts as the linked identity. The target id is the native object id, not the projection id. |
| ActivityPub | Parent `Create` plus reply `Create`, at the visibilities the user confirmed. No activity for a native-only reply. |
| Consent | Required before the parent is created. Required again for the native post if it is a separate button. |
| Idempotency | Auxiliary parent unique index. Reply post uses the normal status idempotency the client already has. Native reply uses `idempotency_key` so a retry does not double-post. |
| Failure | If the parent is created and the reply save fails, the parent remains; it was disclosed in the confirm step. Native failure does not delete a Fediverse reply that already succeeded. `state = failed`, retryable only while the credential is usable. |
| No identity / revoked | Fediverse reply can still be offered. Native reply is refused before any local "sent" state. |

### Boost / repost / undo

| | |
| --- | --- |
| Local effect | Fediverse share creates a standalone reference Note (`Create`). It does not create a reblog of the projection. Native repost creates an `external_activities` row. |
| Native side | Provider repost as the linked identity, targeting the native object id. Undo targets `native_activity_id`. |
| ActivityPub | `Create` of the reference only. No `Announce` of the external object. Undo of a native repost does not emit ActivityPub `Undo` unless the user separately unreblogs their own reference Note. |
| Consent | Explicit for each side. |
| Idempotency | Native partial unique index. A second share click creates another standalone Note only when the user confirms another share. |
| Failure | Same split as favourite: each side's failure is visible and does not forge the other side's success. |
| No identity / revoked | Fediverse share can proceed. Native repost is refused. |

### Quote

| | |
| --- | --- |
| Local effect | Quote status whose `quote_id` is the auxiliary parent. |
| Native side | None unless a later provider capability exists. AT quote-post is not in the first native slice; do not map it onto reply silently. |
| ActivityPub | `Create` with the existing quote URI fields pointing at the parent's local URI. |
| Consent | Same parent warning as reply. |
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
| Idempotency | Auxiliary parent unique index. Repeating the reply action reuses the parent. |
| Failure | A failed `Create` delivery follows today's distribution retry. The private projection is unchanged. |
| Visibility change | Editing the reference Note uses `UpdateStatusService` like any other post. Editing a projection through that service is refused. Promoting a projection to public by changing `visibility` is refused: the public object must be a new reference built from the template, not the projection row with a new visibility. |

## Deletion, disconnect, and moderation

- **Delete projection.** Discard the local status through a path that does not call `remove_from_remote_reach`. Shared resource remains.
- **Delete reference Note.** Normal status removal. Because this Note was federated, normal Delete delivery applies to it. The projection remains.
- **Disconnect identity.** Provider page calls `revoke!` or `delete!` on the vault. Set `disconnected_at`. Delete inbound rows and pending outbound activities for that identity. Keep public-source projections. Succeeded native activities stay as history with no token.
- **Delete user.** Existing account deletion removes statuses. Projection markers cascade. Credentials cascade from `User`. Subscriptions, identities, groups, snapshots, and private blobs cascade from `user_id`. Shared sources, resources, and actors stay.
- **Suspend user.** Workers for that `user_id` no-op. Projections are already owner-only.
- **Mute external actor.** Owner-level `external_actor_mutes` only.
- **Reports.** A projection is not a reportable remote account. The owner's federated reference Note is reportable like any other post.
- **Blocks and domain blocks.** They continue to apply to real accounts. They are not how an RSS host is silenced. An instance that wants to refuse a host does it with the bridge's fetch allow/deny list in a later phase, defaulting to the SSRF checks already in `Request`.

## Deliberately not bridged

- A public or per-user synthetic actor for an external author or feed.
- Cross-user comments, reader lists, favourite counts, or popularity ranks for external resources.
- Copying external body or media into a federated Note.
- Automatic ActivityPub delivery of native inbound likes, replies, or reposts.
- `Announce` of an external URL or of a projection.
- Merging objects because the text or the URL looks similar.
- A Fedibird-operated PDS, hybrid account, or AT account migration.
- Enabling `PostingIdentity` `bluesky`.
- X and mixi2 adapters, until a later issue sets `terms_state`.
- A generic plugin loader or a generic secret POST.
- New values of `Account.protocol`, a `statuses.protocol` column, or `ap_object_type` as a source protocol.
- Putting authenticated bodies or tokens into Redis, Chewy, logs, Sidekiq arguments, REST, or the shared tables.

## Roadmap

Each slice is its own review, flag default **off**, and safe to merge without turning the feature on. Workers no-op while their flag is off. Flags are instance settings, not a hidden default-on path.

| Phase | Flag | Delivers | Depends on | Gate |
| --- | --- | --- | --- | --- |
| P1 | `external_bridge_rss` | Public RSS/Atom subscribe, shared public cache, private projection, fail-closed list, owner extension. No credentials. | This document | The fail-closed list lands in the same change as the writer. Flag stays off until those specs pass. Authenticated feeds are rejected. |
| P2 | `external_bridge_atproto` | Bluesky provider page, `external_identities`, vault credential, fixed hosts, connection test. No timeline import required. | Registry and vault, which exist now | No token in logs or pages. Catalog shows the provider only when the page exists. |
| P3 | `external_bridge_native_actions` | AT like, repost, reply, undo, and the state machine. | P2 | Opt-in per action. Revoked and missing identity covered by specs. |
| P4 | `external_bridge_inbound` | Private inbound replies, likes, and reposts for the owner's identity. | P2. Reply-back uses P3. | No `Notification` or remote `Account` rows. |
| P5 | `external_bridge_publication_groups` | Explicit crosspost groups and owner-only per-platform counts. | P3 and P4 for native counts. Local projection counts can display earlier. | Counts are not written to `status_stat` or trends. |
| P6 | `external_bridge_ap_reference` | Reference Notes and auxiliary parents. | P1, plus the Bridgy Fed experiment | Experiment result recorded. Content template tested. Projection ids absent from ActivityPub. |

X and mixi2 are not a phase. A future issue can add a provider only after `terms_state` is an explicit decision.

P1 verification is the matrix in `docs/private_external_bridge_audit.md`. Performance check for P1 is the unique lookup on `status_id` during status create callbacks, explained against the index, not a new column on `statuses`.

P2's connection test calls one fixed endpoint and returns only safe metadata (handle, subject). It does not print the token or the vault error's raw payload.

## Review decisions

These are chosen in this document so P1 can be written without inventing a boundary. They are still open to change before P1 merges.

1. **No phantom actor.** Stock clients show the owner's account on a projection. Confirm or replace with a design that still is not Webfinger-discoverable and still fails `owned?` safely.
2. **Fediverse share is `Create` of a link Note, not `Announce` of the external URL.** Confirm before any experiment tries Announce.
3. **One auxiliary parent per user and resource; every explicit share is a new Note.** Confirm.
4. **Disconnect deletes inbound payloads and pending outbound activities, and keeps public RSS projections.** Confirm.
5. **First AT slice refuses user-supplied PDS hosts.** Confirm before custom PDS work.
6. **Projection bodies stay out of `StatusesIndex`, unlike today's personal posts.** Owner search of imports needs a later index keyed by `user_id`.
7. **P1 does not download external media into `media_attachments` or public system paths.**
8. **Ordinary personal-status Delete reach is unchanged by P0.** Projection deletion must not use it. A fix for ordinary personal deletes is a separate issue.
9. **X and mixi2 stay unreviewed.** No implementation schedule is implied.
10. **Bridgy Fed behavior with a link Note is an experiment, not a guarantee.**

## What P1 can take from this document without guessing

- The owner is `user_id`. The status account is that user's real local account. There is no synthetic actor.
- The shared cache has no user id and no authenticated body.
- The projection status is a different row from the reference Note, and only the reference Note has an ActivityPub URI.
- Favourite and bookmark are local unless a later opt-in says otherwise.
- Reply, boost, and quote of a projection are refused on the ordinary API.
- Secrets stay in the vault. The identity table is the connection.
- The fail-closed list is part of P1, not a follow-up, and the RSS flag stays off until it is tested.
