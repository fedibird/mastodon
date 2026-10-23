# External feed routing

Parent plan: issue #541. E3 plan: issue #546. E3-A is issue #547. E3-B1, issue #549, is the server streaming slice. E3-B2, issue #550, is the WebUI, Mix, TimelineSeek, and reconnect reconciliation. This document records the route/REST contract and the B1 streaming contract.

Related contracts:

- `docs/external_status_visibility.md` — visibility `external` (201), the read predicate, and the E2 storage switch.
- `docs/private_external_bridge.md` — P0 projection contract. Production RSS still stores `visibility = personal` until an operator turns on the E2 switch. E3 does not perform that migration.

E3-A and E3-B1 are not a rollout. `external_bridge_feeds` and `external_bridge_feeds_testers` ship false and empty. Do not enable them, and do not treat delivery as ready for testers, until E3-B2 has also been reviewed. B1 does not turn the flag on.

## What E3-A implements

- `external_feed_routes` stores a delivery choice for one user and one subscription. It does not copy the status. `destination` is `home` or `list`. Home has `list_id` NULL. List requires it.
- Home is unique per user and subscription. List is unique per user, subscription, and list. A composite foreign key `(external_subscription_id, user_id)` references `external_subscriptions (id, user_id)`, so a route cannot name another user's subscription. That unique pair is new on the small subscriptions table because the existing `(id, user_id, external_source_id)` key cannot be the target of a two-column foreign key.
- List ownership is checked in the update service and again by a trigger: `lists.account_id` must equal `users.account_id` for that route's user. The service and the insert trigger lock the user row, then the list row, with `SELECT ... FOR SHARE`, so an uncommitted `lists.account_id` change finishes before the route is added. Changing `lists.account_id` while a route points at the list is rejected. Changing `users.account_id` is rejected while that user has a projection or a feed route, including a route whose subscription has no projection. Deleting the list deletes the route only. Deleting the subscription deletes the route through `ON DELETE CASCADE` and `dependent: :delete_all`. Projections still go through `ProjectionPurge` before the subscription row is destroyed. A list or route delete does not purge projections.
- `external_subscriptions.feed_routes_revision` starts at 0. The update service locks the subscription, checks the revision the page sent, validates the whole list set, and writes the difference. A no-op does not change the revision or `updated_at`. A stale revision writes nothing. An invalid list rolls the transaction back. Missing `home`, `list_ids`, or `expected_revision` is rejected rather than treated as "clear everything".
- The RSS settings page can edit destinations for a subscription the signed-in user owns. The form is separate from pause, resume, and unsubscribe. New and resumed subscriptions do not receive a home route. The page does not offer the editor to someone who cannot add routes and has none saved. Someone who already has routes can clear them while the delivery flag is off. Additions require the delivery flag and a tester id.
- `ExternalBridge::Feeds::Query` is the shared read. It returns status ids for one user and one destination. Eligible rows are visibility 201, `external_projection`, local, `uri` NULL, searchability personal, not a reply, boost, or quote, not deleted, not expired, marker `source_deleted` false, and a matching route. The marker's user, account, subscription, and resource must still line up. Pause and error are not membership filters. Legacy visibility 200 projections are not eligible and are not rewritten.
- `ExternalBridge::Feeds::Compose` merges those ids with the ordinary Redis feed's selectable ids, deduplicates, limits, then hydrates the page. Home and list REST use it only when the delivery flag permits the authenticated user. `Feed#get` without that user still applies `NOT_PROJECTION_SQL`. `PushUpdateWorker` still returns before publishing a private projection.
- Home `visibilities` filters by the stored value. `direct` and `personal` do not select a row stored as 201. `external` does. Omitting the parameter selects eligible external rows. The Fedibird home column currently sends a stored-visibility list that does not include `external`, so that column does not show these rows yet. The list timeline has no visibility parameter, so a saved list route is visible on the list REST read.
- While `HomeFeed#regenerating?` is set, compose does not merge external ids and the response stays 206. An external-only page is not treated as a finished rebuild.
- Serialization stays `visibility=direct`, `visibility_ex=external`, `fedibird_external.interaction=local_only`. Reply, boost, and quote stay refused.

## What E3-A does not implement

- The streaming server in E3-B1, described below. E3-A did not publish projections.
- A WebUI handler, home visibility change, Mix, TimelineSeek, live/history, or positional bookmarks. Those remain E3-B2. There is no Redis feed history and no rebuild worker.
- Account-shared Redis home and list keys. External ids are not inserted there.
- Mix, TimelineSeek, live/history, and reading bookmarks. They still read the ordinary feed. See the audit below.
- A JSON route API for third-party apps. Route edits are the HTML form. Third-party apps read through the existing home and list REST endpoints.
- E2 migration of legacy personal projections. E4 link notes, boosts, quotes, and `unlisted`. Bluesky import or native actions.
- Enabling the flag or filling the tester list in any environment file.

## Data and authorization

| Check | Where it is enforced |
| --- | --- |
| Route user is the subscription user | Composite foreign key on `external_feed_routes` |
| Home/list shape | Check constraint, model validation, update service |
| Home and list uniqueness | Partial unique indexes |
| List account is the user's account | Update service, insert/update trigger (`FOR SHARE` on the user, then the list), and the read query |
| List account cannot move under a route | Trigger on `lists.account_id`. A route insert waits on that row |
| User account cannot move under a route or a projection | Trigger on `users.account_id` |
| Reader is the marker's user | Query `user_id`, then `ProjectionAccess` on the hydrated page |
| Delivery flag | `ExternalBridge::Feeds::Feature`. Off skips the merge. The query also returns nothing. |

The authenticated `current_user` is the only owner input. `params[:user_id]`, `Account#user`, and an admin role are not substitutes. Two users of one account have independent subscriptions, routes, and statuses. A route with no marker is not readable. A marker with no route is not on home or list. Individual status GET and bookmarks keep the existing owner-only behavior, including `source_deleted` rows, which this feed query excludes.

The id query and the post-hydrate `eligible_ids` check are one request's snapshot. They are not reused on the next request. A row that disappears between those reads is dropped. The page is shorter. The code does not loosen the predicate to fill the gap.

## Cursor

Ordinary ids come from `Feed#candidate_scan`. `max_id`, `since_id`, and `min_id` are exclusive integer member ids. `min_id` walks toward newer ids and the response is still newest-first. `since_id` keeps the newest page above the floor. The scan stops at `FeedManager::MAX_ITEMS` raw ids.

Redis stores the score as an IEEE double, so integer scores are exact only through ±2^53. The read uses the inclusive score of the integer bound, then keeps and orders members by the original integer id. A score that the limit would split is read in full (capped at 4096 members, above the widest signed-bigint gap) before the page cuts it. The next walk starts at the last integer id returned, so unread members of that score stay available. The scan does not rewrite the Redis feed.

`exhausted` means the Redis range for this cursor was read to the end. A budget that stops on a full batch probes one more integer id. An empty probe is the end of the range. A probe that finds a member leaves `exhausted` false and does not move `frontier_id`. `frontier_id` is the last raw integer id examined. External ids may extend past that frontier only when the Redis range is exhausted. Otherwise the external read is limited to the examined side of the frontier, so a partial ordinary scan cannot be closed by an older external id. A visibility filter of only `external` does not walk Redis: an ordinary member cannot match it, and the external read uses the request bounds. The merged page is at most `limit` ids. Link headers use the first and last id of that page. Home links also keep `visibilities` and `compact` when the request sent them. An empty page does not emit a Link header.

Hydration prepares projection owner and marker for every status on the merged page in one read, then applies the same per-row check. A permitted user with no route for that destination does not run the merge.

This bounded merge was checked with query counts and `EXPLAIN` on the test database. That is not a production measurement.

## Flag off

Off, or a user who is not listed, uses the ordinary `Feed#get` path for home and list. Saved routes and statuses stay. The settings page does not advertise destinations to someone with no saved routes. Clearing a saved route is still allowed for that owner. RSS pause, RSS off, and the E2 storage switch do not remove a canonical external row from a route that is already saved. Turning the E2 switch off does not forbid reading an existing 201 row through this path; the delivery flag does.

## Call-site audit

E3-B still has to make these agree with the membership query. None of them gained an external merge in this slice.

| Call | User available | E3-A |
| --- | --- | --- |
| `Api::V1::Timelines::HomeController` | Yes, `current_user` | Merges when the delivery flag permits and the home feed is not regenerating |
| `Api::V1::Timelines::ListController` | Yes | Merges for that user's list when the flag permits |
| `TimelineSeek::Resolver` home and list | The resolver has a user, but it constructs `HomeFeed` / `ListFeed` from the account only | Unchanged. Do not infer the user from `Account#user` |
| `Api::V1::Timelines::SeekController` and memberships | Yes, passed into TimelineSeek | Unchanged, because the resolver above is unchanged |
| WebUI home column (`getHomeVisibilities`) | Requests stored visibilities without `external` | Unchanged in B1. REST still omits external rows until the client asks for stored `external` or omits the filter. B2 owns that client change |
| WebUI list column and Mix sources that poll home or list REST | Uses those endpoints | List polls can show a saved route. Home polls do not, for the visibility reason above. B1 does not change these readers |
| `PersonalFeed`, `PublicFeed`, `TagFeed`, `GroupFeed`, `AccountStatusesFeed`, tag and public HTML | Account or anonymous | Unchanged. `NOT_PROJECTION_SQL` or the personal visibility predicate still applies |
| `PushUpdateWorker` and `FanOutOnWriteService` | Account fan-out | Unchanged. A private projection still returns before `redis.publish`. B1 does not put external bodies on `timeline:<accountId>`, `timeline:list:<listId>`, public, or direct |
| `streaming/index.js` | Authenticated `user` and `list` sockets | B1 additionally subscribes those sockets to the owner's private channels. The public `stream` label stays `user` or `list`. Notification, preferences, public, and direct do not attach |
| RSS refresh and `ProjectionWriter` | Owner user | B1 schedules a content event after the outermost commit when the new row is canonical and delivery is permitted. They still do not create routes |
| Route updates, list deletion, unsubscribe, `ProjectionPurge` | Owner user | B1 schedules the control or delete event described below |

B1 is the user-scoped channel and the generation check. TimelineSeek, live/history, and Mix still read the ordinary feed. A route change is not a status delete. B1 does not emit ActivityPub, webhooks, notifications, or shared streaming events.

## E3-B1 streaming

B1 publishes to private Redis channels and folds those messages into an already authenticated `user` or `list` connection. Clients keep subscribing to `user` and `list`. The server does not require a new public stream name. WebSocket frames keep `stream: ["user"]` or `stream: ["list", listId]`. SSE keeps `event:` plus `data:`. List ids in a WebSocket subscribe frame have to be decimal strings. A JSON number above 2^53 is already rounded before the server sees it.

### Private channels

```
timeline:external:user:<user_id>:home
timeline:external:user:<user_id>:list:<list_id>
timeline:external:user:<user_id>:control
```

`<user_id>` comes from the access token's `resource_owner_id`. A client `user_id`, `Account#user`, or an admin role is not accepted. Node keeps every id as a decimal string. `read` and `read:statuses` are still the streaming scopes for `user` and `list`. `read:lists` does not gain streaming access, and `read:statuses` is not newly rejected. REST list timelines still use their own scope. `read:notifications` does not receive external bodies or ids.

`user` listens to the home channel and the control channel. `list` listens to that list's channel and the same control channel. Notification, preferences, public, direct, anonymous, and account-only connections do not attach. Attaching does not require a route row, so a route added after subscribe is still receivable on the open socket. Turning the flag on, or adding a tester, does require a new subscribe: the private channels are attached only when that check passes. Turning the flag off, removing a tester, revoking or expiring the token, or suspending the user stops delivery on the next private message without a reconnect. Ordinary account-timeline messages do not wait on this query.

### Events

| Event | When | Payload |
| --- | --- | --- |
| `update` | First successful publish for that status. This is also the event when a newer edit runs before any insert was published | REST status JSON for the owner user, same shape as a home/list read. `id` is a string |
| `status.update` | A later generation after one publish has succeeded | Same JSON, current text |
| `delete` | Physical purge committed | The status id as a string, not an object. Not used for route removal or `source_deleted` |
| `external_feed_changed` | Route change, list removal, unsubscribe, `source_deleted`, `source_restored` | `version` 1, `reason`, `targets`, `subscription_id`, `feed_routes_revision`. `status_id` only for `source_deleted` and `source_restored`. No body and no URL |

Content events go to the home and/or list channels that `Feeds::Query` currently accepts. One status id is used on every destination. Control events go only to the control channel. Node forwards a control event to a connection when `targets` contains that connection's home or list. A strictly older `feed_routes_revision` for the same subscription is dropped on that connection. The same revision is forwarded again, so a repeated `source_deleted` still arrives.

The renderer passes the marker's user as `scope:`. It does not call `InlineRenderer`, which would recover `current_user` from `Account#user` and would attach the other user's projection fields. `favourited` and `bookmarked` stay account-scoped, matching REST. `fedibird_external`, including `canonical_url`, is present for that owner because REST already returns it. The private renderer does not add `_fedibird_searchable_text`. Node strips the key if a payload has it. `user` and `list` still have `needsFiltering: false`, so Node does not apply keyword filters on these streams. The same is true of an ordinary user or list event.

API visibility remains `direct` with `visibility_ex=external`. The status is not added to the direct stream or a DM conversation.

### Who may receive a private event

Checked again immediately before Node forwards a private message. A database or Redis error fails closed. Ordinary account events do not run this query.

| Check | Content, delete, and control |
| --- | --- |
| Token not revoked or expired, `resource_owner_id` matches the user and the account | Required |
| User functional: confirmed, approved, not disabled, account not suspended, memorial, or moved | Required |
| `external_bridge_feeds` on and the user id is in `external_bridge_feeds_testers` | Required. Compared as a decimal string, not as a JavaScript number |
| List row still owned by the token account | Required for a `list` connection. A deleted list stops later events on that socket |
| Current route membership | Ruby, via `Feeds::Query`, before a content publish. Node does not infer visibility. Delete and control still forward after the route row is gone, because the captured destination or the control target says so |

An in-flight authorize is tied to one subscription ticket. Unsubscribe, a replaced subscribe, or a closed socket deactivates the ticket. A late result does not subscribe and does not deliver. Each WebSocket subscribe and each SSE request has its own ticket. Duplicate subscribe of the same channel reuses the existing listener.

### Commit boundary

`AfterOuterCommit` registers a transaction record. Rails 6.1 moves that record onto a joinable parent when a savepoint commits, and cancels it if that parent rolls back. The block therefore does not run merely because `requires_new` released a savepoint. A top-level transaction runs it after COMMIT. The test fixture transaction is not joinable, so an example observes the job when its own transaction commits, which is the same rule as `after_commit`.

New and edited text enqueue only when the status and the marker have been saved in that transaction. `RSS::Materialize#refresh_existing` writes the marker and the status text in one transaction. A failure while saving the text rolls the marker back. The same revision, a 304-equivalent refetch, and a `checked_at` change do not enqueue. `source_deleted` or `source_restored` saves the text and the marker together and enqueues only `external_feed_changed`.

Job arguments are the user, projection, status, and subscription ids, the event kind, and the generation. They are decimal strings. The worker reads the current row. It does not store a body snapshot. Logs on failure contain those ids, the event kind, and the exception class.

### Generations

`external_status_projections.content_generation` increments when a content event is enqueued. `streamed_content_generation` is set only after Redis accepts the publish. Both columns live on the marker. Deleting the status cascades the marker away. Nothing is backfilled. The nullable streamed column and the constant default `0` do not rewrite `statuses`. `db:migrate:down VERSION=20261025120000` drops only those two columns.

The worker publishes only when the job's generation is the marker's current generation and the user is still functional and permitted. A stale generation is ignored, so an older job cannot write an older body back. If nothing has been streamed, the publish is `update` even when the winning job was an edit that ran first. If a create was streamed and a later edit commits, the later job is `status.update`. No routes at worker time publishes nothing and does not mark streamed. Adding a route does not backfill content events; it sends `external_feed_changed` only. A create that commits before any route exists is visible to a later REST read once a route exists.

This is not exactly-once. A retry can deliver the same status id again. A narrow race can deliver two `update` events for one generation; clients already replace by id. If Redis publish raises, streamed generation stays unset and Sidekiq retries. If enqueue itself fails after commit, the generation has advanced and the event is not replayed until a later content change. Events skipped because the flag was off are not replayed when the flag is later turned on. A dropped pub/sub message is recovered from REST. An already displayed row whose body, deletion, or route changed is reconciled by E3-B2 against the displayed ids and the membership query. There is no Redis history of these events and no rebuild job.

A future control revision is ignored by the worker. An older revision may still be delivered. It asks the client to re-read; it does not recreate routes. `subscription_removed` is sent only when the subscription row is gone. No-op route writes do not bump `feed_routes_revision` and do not enqueue. List deletion bumps the revision in `before_destroy`, including the `delete_all` of routes, so an older route job cannot treat the list as current. That path does not depend on the settings service alone. While the flag is off the revision still advances and no control event is sent.

### Purge

`ProjectionPurge` captures the canonical owner, the status id, and the destinations before `delete_all`. The capture is visibility 201 and `external_projection` only. Destinations are the owner's home channel plus each list route that existed. The delete job is enqueued after the outermost commit. The worker sends `delete` only when that status row and that user's marker are gone. A living status produces nothing. The captured hash is built inside the purge, not accepted from a public API. User deletion through `ExternalBridge::DeleteUser` does not emit deletes: the user is going away, and revocation wins over delivery. Account deletion suspends or removes the user before the after-commit worker runs, so the worker fails closed. Deletes are batched 100 ids per job. The Sidekiq arguments are the only outbox. A lost job is not replayed from a table. The next REST read, and B2 for rows already on screen, are the recovery. Another user's status or bookmark for a different row is not addressed.

### E3-B2

B1 does not change `app/javascript/mastodon/actions/streaming.js`, `getHomeVisibilities`, Mix, TimelineSeek, or positional bookmarks. B2 still has to:

- handle `external_feed_changed` in the WebUI
- include stored `external` in the home column's visibility request
- reconcile an open timeline after reconnect, using the displayed status ids and `Feeds::Query`
- use the same membership for live/history, Mix, and TimelineSeek
- treat a route removal or `source_deleted` as a reload of that view, not as `delete`

A third-party client that ignores `external_feed_changed` sees the change on its next REST fetch. `delete` remains the signal that the status row is gone, including a copy cached on the owner's user stream.

## Rollback

`db:migrate:down VERSION=20261025120000` drops `content_generation` and `streamed_content_generation` from `external_status_projections`. It does not rewrite `statuses` or delete markers. `db:migrate:down VERSION=20261024120000` restores the previous route-owner function and the previous user-account guard. It does not drop routes or projections. `db:migrate:down VERSION=20261023140000` drops the route triggers and table, then the subscriptions revision column and the `(id, user_id)` unique index. It does not rewrite `statuses` or delete projections. Routes disappear with the table. Taking the code back while rows of visibility 201 exist is still the E1/E2 rule: do not roll the application back past the code that understands visibility 201.
