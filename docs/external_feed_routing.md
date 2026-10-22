# External feed routing

Parent plan: issue #541. E3 plan: issue #546. This document is the E3-A slice, issue #547. It records what the route and REST change implements and what it leaves for E3-B.

Related contracts:

- `docs/external_status_visibility.md` — visibility `external` (201), the read predicate, and the E2 storage switch.
- `docs/private_external_bridge.md` — P0 projection contract. Production RSS still stores `visibility = personal` until an operator turns on the E2 switch. E3 does not perform that migration.

E3-A is not a rollout. `external_bridge_feeds` and `external_bridge_feeds_testers` ship false and empty. Do not enable them, and do not treat this slice as ready for testers, until the streaming work in E3-B exists and has been reviewed.

## What E3-A implements

- `external_feed_routes` stores a delivery choice for one user and one subscription. It does not copy the status. `destination` is `home` or `list`. Home has `list_id` NULL. List requires it.
- Home is unique per user and subscription. List is unique per user, subscription, and list. A composite foreign key `(external_subscription_id, user_id)` references `external_subscriptions (id, user_id)`, so a route cannot name another user's subscription. That unique pair is new on the small subscriptions table because the existing `(id, user_id, external_source_id)` key cannot be the target of a two-column foreign key.
- List ownership is checked in the update service and again by a trigger: `lists.account_id` must equal `users.account_id` for that route's user. Changing `lists.account_id` while a route points at the list is rejected. Deleting the list deletes the route only. Deleting the subscription deletes the route through `ON DELETE CASCADE` and `dependent: :delete_all`. Projections still go through `ProjectionPurge` before the subscription row is destroyed. A list or route delete does not purge projections.
- `external_subscriptions.feed_routes_revision` starts at 0. The update service locks the subscription, checks the revision the page sent, validates the whole list set, and writes the difference. A no-op does not change the revision or `updated_at`. A stale revision writes nothing. An invalid list rolls the transaction back. Missing `home`, `list_ids`, or `expected_revision` is rejected rather than treated as "clear everything".
- The RSS settings page can edit destinations for a subscription the signed-in user owns. The form is separate from pause, resume, and unsubscribe. New and resumed subscriptions do not receive a home route. The page does not offer the editor to someone who cannot add routes and has none saved. Someone who already has routes can clear them while the delivery flag is off. Additions require the delivery flag and a tester id.
- `ExternalBridge::Feeds::Query` is the shared read. It returns status ids for one user and one destination. Eligible rows are visibility 201, `external_projection`, local, `uri` NULL, searchability personal, not a reply, boost, or quote, not deleted, not expired, marker `source_deleted` false, and a matching route. The marker's user, account, subscription, and resource must still line up. Pause and error are not membership filters. Legacy visibility 200 projections are not eligible and are not rewritten.
- `ExternalBridge::Feeds::Compose` merges those ids with the ordinary Redis feed's selectable ids, deduplicates, limits, then hydrates the page. Home and list REST use it only when the delivery flag permits the authenticated user. `Feed#get` without that user still applies `NOT_PROJECTION_SQL`. `PushUpdateWorker` still returns before publishing a private projection.
- Home `visibilities` filters by the stored value. `direct` and `personal` do not select a row stored as 201. `external` does. Omitting the parameter selects eligible external rows. The Fedibird home column currently sends a stored-visibility list that does not include `external`, so that column does not show these rows yet. The list timeline has no visibility parameter, so a saved list route is visible on the list REST read.
- While `HomeFeed#regenerating?` is set, compose does not merge external ids and the response stays 206. An external-only page is not treated as a finished rebuild.
- Serialization stays `visibility=direct`, `visibility_ex=external`, `fedibird_external.interaction=local_only`. Reply, boost, and quote stay refused.

## What E3-A does not implement

- Streaming, a private Redis feed, a rebuild or reconcile worker, and publication through `PushUpdateWorker`.
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
| List account is the user's account | Update service, insert/update trigger, and the read query |
| List account cannot move under a route | Trigger on `lists.account_id` |
| Reader is the marker's user | Query `user_id`, then `ProjectionAccess` on the hydrated page |
| Delivery flag | `ExternalBridge::Feeds::Feature`. Off skips the merge. The query also returns nothing. |

The authenticated `current_user` is the only owner input. `params[:user_id]`, `Account#user`, and an admin role are not substitutes. Two users of one account have independent subscriptions, routes, and statuses. A route with no marker is not readable. A marker with no route is not on home or list. Individual status GET and bookmarks keep the existing owner-only behavior, including `source_deleted` rows, which this feed query excludes.

The id query and the post-hydrate `eligible_ids` check are one request's snapshot. They are not reused on the next request. A row that disappears between those reads is dropped. The page is shorter. The code does not loosen the predicate to fill the gap.

## Cursor

Ordinary ids come from `Feed#candidate_scan`. That walk matches the previous Redis refill: exclusive `max_id`, `since_id`, and `min_id`, with `min_id` walking toward newer ids and the response still newest-first. `since_id` keeps the newest page above the floor. The scan stops at `FeedManager::MAX_ITEMS` raw ids.

`exhausted` means the Redis range for this cursor was read to the end. `frontier_id` is the last raw id examined. External ids may extend past that frontier only when the Redis range is exhausted. Otherwise the external read is limited to the examined side of the frontier, so a partial ordinary scan cannot be closed by an older external id. The merged page is at most `limit` ids. Link headers use the first and last id of that page. Home links also keep `visibilities` and `compact` when the request sent them. An empty page does not emit a Link header.

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
| WebUI home column (`getHomeVisibilities`) | Requests stored visibilities without `external` | REST will not include external rows until the client asks for stored `external` or omits the filter. Live updates still depend on streaming |
| WebUI list column and Mix sources that poll home or list REST | Uses those endpoints | List polls can show a saved route. Home polls do not, for the visibility reason above. Streaming updates still do not |
| `PersonalFeed`, `PublicFeed`, `TagFeed`, `GroupFeed`, `AccountStatusesFeed`, tag and public HTML | Account or anonymous | Unchanged. `NOT_PROJECTION_SQL` or the personal visibility predicate still applies |
| `PushUpdateWorker`, `FanOutOnWriteService`, `streaming/index.js` | Account fan-out and shared channels | Unchanged. Projections are still not published. Node does not filter them, so Ruby must not start publishing them on the shared channel |
| RSS subscribe, pause, resume, refresh, `ProjectionWriter` | Owner user | Unchanged. They do not create or refresh routes |

E3-B needs a user-scoped delivery channel, generation checks when a route changes, and the same membership for TimelineSeek, live/history, and Mix. A route change is not a status delete. This slice does not emit ActivityPub, webhooks, notifications, or shared streaming events for a route write or a home/list read.

## Rollback

`db:migrate:down VERSION=20261023140000` drops the route triggers and table, then the subscriptions revision column and the `(id, user_id)` unique index. It does not rewrite `statuses` or delete projections. Routes disappear with the table. Taking the code back while rows of visibility 201 exist is still the E1/E2 rule: do not roll the application back past the code that understands visibility 201.
