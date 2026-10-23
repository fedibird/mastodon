# External link sharing

Parent plan: issue #541. E4 plan: issue #555. This document is the E4-A contract (issue #556) and the E4-B contract (issue #558, section "E4-B: boost and unboost of a projection").

Related contracts:

- `docs/external_status_visibility.md` — projection visibility, the read predicate, and the `direct` / `visibility_ex=external` mask.
- `docs/external_feed_routing.md` — E3 home and list delivery. It does not publish a projection.

E4-A is not a rollout. `external_bridge_link_sharing` and `external_bridge_link_sharing_testers` ship false and empty. Generation fails closed while they are off. E4-A does not convert boost, unboost, reply, or quote, does not change a projection's REST visibility, and does not add a boost button. E4-B converts boost and unboost only, behind the same two switches.

## Projection and reference Status

A projection stays a private status: `external_projection=true`, `uri=nil`, visibility `external` or legacy `personal`, searchability `personal`. `ExternalBridge::Guards.reject_target!` still refuses it as a reply, boost, quote, reaction, edit, or pin target. REST stays `visibility=direct` and `visibility_ex=external` for a canonical external row.

A reference note is a different status on the same real Account. It is a normal local public or unlisted post. It has a URI, goes through the normal Status create callbacks, and is distributed once `published_at` is written. It is not an external projection and it does not carry `fedibird_external`.

The note text is an allowlist, one field per line, with blank lines omitted:

```
{sanitized ExternalSource title}
{protocol label}
{normalized canonical URL}
```

The protocol label is `RSS` or `Atom`. Any other protocol is omitted. A source title that contains `<` or `>` is omitted rather than parsed. Control characters are removed, and `@` and `#` are removed so the title cannot become a mention or a hashtag. The title is at most 120 characters. The canonical URL is `ExternalBridge::LinkSharing::ArticleURL.normalize!`. Feed fetch URLs still use `ExternalBridge::RSS::CanonicalURL`, which allows only `format=rss|atom|xml|feed`.

Article URLs accept `http` and `https` with no userinfo and no private IP literal. A path URL is accepted. A query is accepted only when every name is one of `p`, `page_id`, `post_id`, `id`, or `name`. `p`, `page_id`, and `post_id` must be positive integers. `id` and `name` may be that integer or a public slug of at most 80 characters from `[A-Za-z0-9_-]`, containing a letter. A slug of 24 or more characters with no hyphen or underscore is rejected. Names are decoded up to eight times before the check, so `%74oken` is the secret name `token` and is rejected. Secret segments include `token`, `key`, `auth`, `signature`, `password`, `secret`, `session`, `jwt`, `code`, `state`, `nonce`, and `oauth`. Unknown names, empty queries, more than three pairs, duplicate names, and malformed percent-encoding are rejected. The stored form lowercases the scheme, host, and query names, strips a default port and a fragment, collapses a root path, sorts the pairs, and strips leading zeros from integers. `https://example.com/?p=123` is stored as `https://example.com?p=123`.

The composer does not read the projection text, spoiler, article title, byline, attachment description, or poll options. Before insert, the service rejects the composed text if any of those values (8 characters or longer, and not themselves the allowed title, label, or URL) occur inside it. HTML from the feed is not stored. REST and ActivityPub render the plain text through the existing Formatter.

## Policy

`external_link_share_policies` is one row per User. It is not default privacy, posting style, or an E3 route. `Account#user` is not used to find the owner.

| Column | Meaning |
| --- | --- |
| `user_id` | The consenting User. Unique. |
| `enabled` | Explicit consent is on. |
| `visibility` | `public` or `unlisted` only. |
| `revision` | Increments on grant, revoke, and a real visibility change. |
| `consented_at` | Set when consent is granted. Required while `enabled`. |

`ExternalBridge::LinkSharing::Policy.grant!` turns consent on, records `consented_at` if it was empty, and bumps `revision`. `revoke!` turns consent off and bumps `revision`. It does not delete a reference note that was already published. `change_visibility!` bumps `revision` only when the stored visibility changes. There is no WebUI for this row in E4-A.

Generation requires the feature flag, a tester id, a functional User, `enabled`, `consented_at`, and `policy.visibility` equal to the requested scope. A missing policy, a revoked policy, or a different scope writes nothing.

## Scope and mapping

`external_projection_link_references` maps one User, one projection, one scope, and one canonical URL to one reference Status.

| Column | Meaning |
| --- | --- |
| `user_id`, `account_id` | Must match the User's account and the reference status account. |
| `external_status_projection_id` | Nullable. Purge sets it null and leaves the note. |
| `projection_status_id` | Snapshot of the projection status id. Not a foreign key. While `external_status_projection_id` is present, the owner trigger requires it to equal that marker's `status_id`. After purge the FK is null and this snapshot stays. |
| `reference_status_id` | The note. Null after the note row is deleted. |
| `visibility` | `public` or `unlisted`. Not widened later. |
| `canonical_url` | Normalized URL identity. |
| `resource_revision` | Audit copy of the resource revision. Not part of reuse. |
| `policy_revision` | Policy revision observed when the row was inserted. |
| `state` | `active`, `superseded`, or `broken`. |
| `published_at` | Set after `PublishStatusService` returns. Null means distribution has not finished and may be retried. |
| `next_recovery_at` | Recovery cursor. Null means unvisited. A future time means Sidekiq accepted a job and the row is held out of the scan until then. A past time means the enqueue was refused or the hold expired. |

Active identity is unique on `(user_id, external_status_projection_id, visibility, canonical_url)` where `state = 'active'` and the projection id is present. `reference_status_id` is unique while present. Another User, including another User of the same Account, has a separate projection and a separate note. A public note is never returned for an unlisted request, or the reverse.

Reuse requires an active row, the same scope, the same normalized URL, and a live reference status that is not discarded and is not a projection. A canonical URL change does not edit the published note. The previous row becomes `superseded` and the next ensure creates a new note for the new URL. `resource_revision` changing alone does not.

A broken row stays broken. A superseded row cannot become active. Deleting the reference status marks the mapping `broken` and clears `reference_status_id` in a `BEFORE DELETE` trigger. A discarded note is marked broken on the next ensure. Ensure and resolve then fail closed and do not create a replacement. A note whose mapping row was removed, with the same account and the same composed text, also fails closed.

## Lock order and generation

`ExternalBridge::LinkSharing::EnsureReference` is the only writer.

1. Reject a nil User, a scope other than `public` or `unlisted`, a disabled flag, a non-tester, or a User who does not own the projection marker.
2. Lock `external_link_share_policies` `FOR UPDATE`.
3. Re-read that locked row. Consent, visibility, and `revision` must still match. This is the check after a lock wait: a revocation or visibility change that committed first is visible here, and no note is inserted.
4. Lock the User's mapping rows for that projection and scope `FOR UPDATE`.
5. Return a healthy active row for the same URL, or mark a damaged one `broken` and raise.
6. Re-read the locked policy immediately before inserting the Status, and again immediately before inserting the mapping. A same-transaction consent or revision change rolls the Status back.
7. Insert the mapping. A unique violation rolls the Status back. The caller loads the committed winner and returns that row instead of inserting another.
8. After that transaction commits, `PublishReference` calls `RecoverySchedule.enqueue!`. The scheduler uses the same method. It sets `next_recovery_at` 30 minutes ahead and only then calls `perform_async`. A returned jid means Sidekiq accepted the job. A second ensure, or a scheduler pass, does not enqueue again while that timestamp is still ahead. `nil` or a Redis connection error clears only that attempt's timestamp, so a claim stored by a later caller stays. The worker locks the mapping row, calls `PublishStatusService`, then sets `published_at`. The projection is not passed to distribution, ActivityPub, webhooks, or the public search index.
9. A later ensure sees `published_at` and does not enqueue again. `PublishStatusService`'s Redis key still expires after 7 days for ordinary statuses. That key is not the reuse decision for a reference. Deleting it, or waiting it out, does not distribute the same note again.
10. If the worker raises before `published_at` is written, Sidekiq retries that job. If the process stops after commit and before an accepted enqueue, no job exists. `Scheduler::ExternalBridgeLinkReferencePublishScheduler` runs every 5 minutes and selects at most 20 rows. It does not call ensure, and it does not read the feature flag or the current policy. Those gates apply when the note is created. A note already inserted is still distributed after the flag is turned off or consent is revoked. Broken mappings, discarded notes, projection statuses, and account mismatches are left unpublished. A second pass, or two workers, take the same row lock and call `PublishStatusService` once.

The scan orders by `next_recovery_at ASC NULLS FIRST, id`. Unvisited rows come first. A row with an accepted jid is not selected again until `next_recovery_at`. That hold is 30 minutes, which covers more than four 5-minute passes, so a job that sits in Redis is not pushed again on every pass. A nil jid or a Redis connection error records `next_recovery_at = now` when that attempt still owns the timestamp, and creates no job. A newer claim is not cleared. The next pass continues with rows that are still null, then comes back to the refused rows. After the hold expires, a head that never finished can be tried once more. That later try is not a new job every pass.

`index_link_refs_on_unpublished_recovery` is `(next_recovery_at ASC NULLS FIRST, id)` where `published_at` is null, `state` is `active` or `superseded`, and `reference_status_id` is present. Published rows are outside the index. Each pass stops at 20 eligible ids and then joins `statuses` for the discard, projection, and account checks. On a tiny table the planner may still sequential-scan. The partial index is the plan once published rows dominate. It does not touch the emoji `INCLUDE` indexes.

## Consent, flag, and emergency stop

The feature flag, the tester list, and the current policy decide whether a new note may be created. They do not decide whether a note that was already inserted is distributed. Turning the flag off, emptying the tester list, or revoking consent stops the next generation. It does not delete the note and it does not cancel distribution. There is no settings screen in this phase. Consent is `ExternalBridge::LinkSharing::Policy` only.

A person who revokes consent should expect existing link notes to remain and to be distributed. Those notes are ordinary public or unlisted posts of their account.

To stop one note that is not yet distributed (`published_at` is null), set that mapping to `broken`:

```sql
UPDATE external_projection_link_references
   SET state = 'broken', updated_at = clock_timestamp()
 WHERE id = :mapping_id
   AND published_at IS NULL
   AND state <> 'broken';
```

The worker and the scheduler both skip `broken`. The Status row stays. This does not recall a Create that already left the server. If `published_at` is already set, distribution has been handed to the normal status pipeline. Stopping that note is a normal delete of the Status, not the feature flag and not a delete of the mapping. Do not drop the mapping to hide a published note. That throws away the only record of which User, projection, and scope it came from.

To pause the sweeper, stop `Scheduler::ExternalBridgeLinkReferencePublishScheduler`. Jobs already in Redis still run. Quieting the queue that runs `ExternalBridge::LinkReferencePublishWorker`, or deleting those jobs, stops accepted work that has not started. The feature flag does not do either of those. A Redis pause does not create jobs: a refused enqueue writes no jid and leaves the row for a later pass.

Policy updates lock only the policy row, so they take the same first lock and do not deadlock with generation. A revocation that blocks on the lock applies after the note for the held revision commits. That note is not deleted. The next generation sees the new revision.

`ExternalBridge::LinkSharing::Resolve` is the read boundary for a later boost conversion. It does not create a note and it is not a public API. Flag off, a non-owner, and a broken mapping fail closed. No active row returns nil.

## Lifecycle

| Event | Reference note | Mapping |
| --- | --- | --- |
| `source_deleted` | Kept if it already exists. Returned again for the same URL. Not newly created. | Unchanged while the projection remains. |
| Subscription delete / `ProjectionPurge` | Kept. No ActivityPub Delete is sent for it. | `external_status_projection_id` becomes null. The note is not deleted. |
| Reference status hard-delete | Row is gone. | `state=broken`, `reference_status_id` null. Later ensure fails closed. |
| User delete | The account post remains. `DeleteUser` does not delete it. | Mapping and policy rows cascade away. |
| Account delete | The account's statuses go with the account. | Mapping cascades from the account. |

## Rollback floor

`20261026120000` and `20261027120000` both run inside one transaction. The first statement after `lock_timeout` is `ExternalBridge::Schema::LINK_SHARING_ROLLBACK_FLOOR_SQL`. It locks `external_link_share_policies` and then `external_projection_link_references` in `SHARE ROW EXCLUSIVE` mode, then checks for rows. Those locks block INSERT, UPDATE, DELETE, and `SELECT FOR UPDATE` until the transaction ends, including the `DROP`. They do not lock `statuses`. If either table contains a row, down raises `check_violation` and leaves the tables, triggers, policy, mapping, and reference Status in place. An empty database can go down and back up. Do not delete published notes in order to make down succeed. Dropping the mapping would keep the public Status and throw away the only record of which User, projection, and scope it came from.

## E4-B: boost and unboost of a projection

E4-B is split. B1 is the state of record and the boost/unboost contract. B2 is the REST read side. Both ship in the same change and both stay behind `external_bridge_link_sharing` (false) and `external_bridge_link_sharing_testers` (empty). Nothing here turns a flag on, and no WebUI control exists.

### What a boost of a projection does

`POST /api/v1/statuses/:projection_id/reblog` by the owner becomes a share of the User's own reference note:

1. `Api::V1::Statuses::ReblogsController` sees that the target is a projection and hands it to `ExternalBridge::LinkSharing::Boost`. It does not call `ReblogService`. `ReblogService` still calls `ExternalBridge::Guards.reject_target!`, and `StatusPolicy#reblog?` still refuses a private status. Both are unchanged. A normal status takes the old path with the old code.
2. `Boost` checks, in order: the authenticated `current_user`, a projection marker with that user's id, the flag and tester list, `User#functional?`, that the projection is canonical (below), the policy row (`enabled`, `consented_at`, `public` or `unlisted`), the request parameters, and that no live share of the User for this projection disagrees with this request (below).
3. `EnsureReference` (E4-A) gets or creates the reference note for the policy's scope.
4. One transaction locks the policy row, then the mapping row, then the User's boost rows, repeats the checks against the locked rows, verifies the reference note (below), and inserts the wrapper Status and the boost row together.
5. After commit the Announce is requested (below).

The wrapper is an ordinary boost Status on the User's Account whose `reblog` is the reference note. It has the policy scope as its visibility. The projection is never nested. No field of the projection (text, spoiler, title, byline, attachment, source authentication string, Status id, or URI) is copied into the wrapper, the reference note, an ActivityPub activity, a notification, or a webhook.

Request parameters never widen the scope. `visibility` is accepted only when it equals the policy scope. Any other value, including `mutual`, `limited`, `private`, `direct`, `personal`, and the other of `public`/`unlisted`, is `422 visibility_mismatch`. `circle_id` is `422 circle_rejected`. There is no fallback to a default privacy.

### Canonical projection only

`Ownership.assert_canonical!` is the entry condition of `Boost` and is checked again by `BoostAnnounce`. The Status must have visibility `external` (201) and `external_projection = true`, and the marker's User, Account, Subscription (same User, same source) and Resource (same source) must agree. A marker on a legacy personal (200) row, or a row that has only the flag or only the visibility, is refused with `422 projection_not_canonical`; no note, mapping, or wrapper is written. Reading, bookmarking, favouriting, E2 migration, and **unboost** of such a row are not affected: unboost needs only the marker. E4-A `EnsureReference` keeps its own contract (it accepts a marker the owner holds); it has no caller other than `Boost`, so legacy 200 is closed at the entry. A legacy row becomes shareable after the E2 migration makes it canonical.

### One live share, one meaning

A repeated POST returns the live share only when it is still the share this request would make: same User, same projection, the current active mapping whose canonical URL equals the resource's current URL, the same reference note, the same consented scope, and a kept wrapper of that Account. Otherwise `409 share_outdated`, before `EnsureReference` runs, so no new note is created or distributed and the old share is neither widened nor moved. The caller undoes the current share (`unreblog`, which sends the Undo for an announced wrapper or removes an unannounced one) and posts again; that creates the new note's Create, then its Announce. The same check runs again under the locks (a URL change that lands between the two returns `409`, and the note that `EnsureReference` made in that window stays unboosted). A source title change alone does not change the share.

### User and Account

| Caller | Boost | Unboost | `reblogged` on the projection |
| --- | --- | --- | --- |
| Owner User | Allowed when flag, tester, and consent hold | Always allowed | `true` while a live share exists |
| Another User of the same Account | `404` (no marker for that User) | `404` | `false`; reads its own rows only |
| Another Account, admin, nil user | `404` | `404` | `false` |
| Forged marker, legacy 200, flag-only Status | `404` | `404` | `false` |

The share row carries `user_id` and `account_id` and a trigger checks that they agree with the mapping, the marker, and the wrapper. A wrapper is never matched by Account and reference Status alone. A boost of the reference note that the Account made by other means is not adopted and not undone: boosting while one exists is `422 reference_already_boosted`.

### State: `external_projection_link_boosts`

One row per share generation. A row is created `active` and ends `undone`. It never becomes active again.

| Column | Meaning |
| --- | --- |
| `user_id`, `account_id` | The sharing User and that User's Account. |
| `link_reference_id` | The E4-A mapping row (the projection, scope, and canonical URL identity). |
| `external_status_projection_id` | Marker. Set null when the projection is purged. |
| `projection_status_id` | Snapshot of the projection Status id. The key `reblogged` reads. |
| `reference_status_id`, `wrapper_status_id` | The note and the boost Status. Set null by the foreign key when a Status row is deleted. |
| `visibility` | `public` or `unlisted`. Equal to the mapping and the wrapper. |
| `generation` | 1, 2, ... per mapping. A new boost after an undo is a new row and a new wrapper. |
| `policy_revision` | Policy revision when the row was inserted. Audit only. |
| `state`, `ended_reason`, `undone_at` | `active` or `undone`, and why it ended. |
| `announced_at` | Committed intent to announce (step 1 below). From here an Undo is owed if the row ends. |
| `announce_enqueued_at` | The ActivityPub job was accepted by Sidekiq (step 2 below). Null with `announced_at` set means the job is still to be enqueued. Requires `announced_at`; immutable once set. |
| `next_announce_at` | Recovery cursor for the Announce, like `next_recovery_at`. |

Database guarantees: one `active` row per `(user_id, projection_status_id)` (partial unique index); `(link_reference_id, generation)` unique; `wrapper_status_id` unique; foreign keys to users, accounts, the mapping (cascade), the marker (set null), and both statuses (set null); checks for state, visibility, generation, `active` requires a wrapper, `undone` requires `undone_at`; an insert trigger that verifies the User/Account pair, the mapping, the marker owner, and the wrapper shape; an update trigger that makes identifiers immutable, makes `announced_at` and `announce_enqueued_at` immutable once set (and `announce_enqueued_at` requires `announced_at`), and refuses to reactivate an ended row; a `BEFORE DELETE` trigger on `statuses` that ends the row (and clears its status ids in the same statement) when the wrapper or the reference note is hard-deleted.

`ended_reason` values: `user_undo`, `projection_purged`, `projection_gone`, `status_deleted`, `wrapper_removed`, `reference_unavailable`, `reference_modified`, `consent_withdrawn`, `feature_changed`. `projection_gone` is also used when the projection is no longer canonical at announce time.

### Create, Announce, Undo

Who emits what:

| Activity | Emitted by | When |
| --- | --- | --- |
| Create (reference note) | E4-A `LinkReferencePublishWorker` through `PublishStatusService` | Once per mapping, at `published_at`. Unchanged. |
| Announce (wrapper) | `LinkSharing::BoostAnnounce`, which enqueues only `ActivityPub::DistributionWorker` for the wrapper | Once per boost row (at-least-once on failure, see "Delivery boundary"), only after the mapping's `published_at` is set. |
| Undo of the Announce | `RemovalWorker` on the wrapper (`RemoveStatusService`) | On unboost, only when `announced_at` (the committed intent) is set. |

Ordering. If the reference note is new, `published_at` is still null when the boost commits, so no Announce is queued. The publish worker writes `published_at`, then pushes the boost rows that were waiting (`BoostSchedule.enqueue_for_mapping!`). The Announce job therefore enters the push queue after the Create distribution jobs. The Announce is never sent for an object that has not been handed to distribution. The scheduler (`Scheduler::ExternalBridgeLinkReferencePublishScheduler`) also scans `RecoverUnannounced` for rows whose job was lost (`announce_enqueued_at` null), and only for mappings whose Create is out. Delivery to separate remote inboxes is separate Sidekiq jobs, so arrival order at a remote server is best effort. A remote server that receives the Announce first fetches the note by URI; the note is public or unlisted and dereferenceable.

Duplicate display. The reference note's own Create fan-out is the only appearance of the share on this server. The wrapper:

- is not given to `DistributionWorker`, so it never enters a home, list, public, hashtag, or subscriber timeline, and no streaming event is made for it;
- is excluded from `FeedManager#populate_home` and `#merge_into_home` rebuilds and from the profile listing used by `GET /api/v1/accounts/:id/statuses` (`Status.without_link_boost_wrappers`);
- creates no notification, trend, or tag use (`ReblogService` is not used).

Followers on other servers receive Create then Announce. This server cannot dedupe their timelines; Mastodon-compatible servers fold a boost of a note that is already in the top of the feed. The ActivityPub outbox of the account still lists the wrapper, as a federation fact. Feed rebuild paths other than the three above are not changed and have no test; a code search found no other reader of an Account's boosts that fills a timeline, but that is a reading, not a proof.

Undo. `POST /api/v1/statuses/:projection_id/unreblog` ends this User's active rows for the projection. The wrapper is discarded and, if it was announced, handed to `RemovalWorker` after commit, which sends the Undo and removes the row. A wrapper that was never announced is removed at once: nothing left the server, and a left-over discarded row would fail the one-boost-per-Account-and-note validation of the next share. The reference note, the projection, the mapping, favourites, and bookmarks are untouched. Repeating the call, or calling it with no share, returns `200` and ends nothing.

Delivery boundary. `BoostAnnounce` is two transactions with one verification function (lock order: policy row `FOR SHARE`, then boost row `FOR UPDATE`; `Boost` takes policy, mapping, boost rows and `Unboost` takes boost rows only, so no lock is taken in the opposite direction).

1. Intent: verify, then commit `announced_at`. No Redis write happens in this transaction.
2. Delivery: lock again, verify again, enqueue `ActivityPub::DistributionWorker` for the wrapper, write `announce_enqueued_at`, commit. The two locks are held across the Redis call.

Verification re-reads the flag, the tester list, the User, the policy, the canonical marker, the mapping (active, same note, same canonical URL as the resource has now), and the reference note. The policy must be the grant the boost was made under: enabled, consented, same scope, **and `policy.revision` equal to the row's `policy_revision`**. Every grant, revoke, and scope change bumps the revision and takes the policy row `FOR UPDATE`, so each either commits before step 2 reads the policy (nothing is sent: the row is closed, `consent_withdrawn`) or waits until step 2 has finished. A change of `external_bridge_link_sharing` or `external_bridge_link_sharing_testers` (their `settings.updated_at`) after the row was created closes it (`feature_changed`). If anything no longer holds the row is closed (`undone`, with a reason) and the wrapper is removed; with `announced_at` still null no Undo is sent, with it set the wrapper is discarded and `RemovalWorker` sends an Undo (harmless if nothing left the server).

Guarantees and their limits.

- Linearization point: the moment Sidekiq accepts the ActivityPub job in step 2. A revocation, scope change, or re-grant that committed before step 2 read the policy stops the Announce. One that commits after the job was accepted does not recall it: the share is then an announced share and only Undo ends it (the public note is never deleted by consent changes).
- Step 2 enqueues only after the intent was committed in step 1, so the job is legitimate whatever happens to step 2's own transaction. If step 2 fails after the enqueue (the `UPDATE` or `COMMIT` fails, the process stops), `announce_enqueued_at` stays null and `RecoverUnannounced` (or a Sidekiq retry) enqueues the Announce again: a duplicate job for the same activity. The Announce id is the wrapper's activity URI, which does not change, so a receiver gets the same activity id twice. Whether it drops the second copy is the receiver's behaviour; this server does not guarantee it.
- A job that was never accepted (nil jid, Redis error, a crash before the enqueue) leaves `announced_at` set and `announce_enqueued_at` null. The row is selected by the scan from the next pass (the claim is released), and the claim keeps a pass from pushing a second job while one is still held in Redis.
- The feature flag and the tester list are settings read without a row lock and through the settings cache. A change committed before the check stops the request; one that lands in the few statements between the check and the enqueue may not stop that single request.
- A User's Undo takes the boost row lock: it either ends the row before step 2 (nothing is enqueued) or waits for step 2 and then sends the Undo. A job for generation 1 cannot touch generation 2, and a job queued before an undo, a consent change, a purge, or an edit cannot bring the share back.
- Two workers for the same row are serialized by the row lock; the second sees `announce_enqueued_at` and does nothing.

### Reference note identity

The reference note is the User's own post and can be edited. At insert, `external_projection_link_references.reference_digest` stores the SHA-256 of the note text. A boost requires the digest to match the current text and the note to be unchanged in shape: same visibility as the mapping, no spoiler, not sensitive, no media, no poll, no quote, no status reference, not a reply, not a reblog, same Account, not discarded. Otherwise `422 reference_modified` (or `reference_broken` for a missing or discarded note) and nothing is written. A change of the source title after the note was created does not matter, because the digest is of the stored text and not of the current title. Reverting an edit makes the note usable again. A row inserted before the digest column existed (`NULL`) is compared with the allowlist text derived from the current source, so it fails closed if the title has changed. The digest is immutable once written.

### Lifecycle

| Event | Share |
| --- | --- |
| Flag off or on again, tester list edited, consent revoked or granted again, scope changed | New boost refused (or `409 share_outdated` for a live share of another scope). A live share stays and can be undone. An unannounced share is closed at announce time (`consent_withdrawn` / `feature_changed`), including after a revoke and a grant of the same scope. An announced share is not recalled. |
| `source_deleted` | Share stays. Boost and undo keep working. |
| Projection purge / subscription delete / user delete | Ended in the purge transaction (`projection_purged`); the Undo is enqueued after commit. The reference note stays. `RecoverUnannounced` also closes any active row whose marker is gone (`projection_gone`). |
| Reference note edited | New boost refused. A live announced share stays. An unannounced one is closed (`reference_modified`). |
| Reference note deleted | Share ended by the trigger (`status_deleted`). The mapping is `broken` (E4-A). |
| Wrapper removed by another path | The share no longer counts for `reblogged`. The next boost or unboost closes the row (`wrapper_removed`). |

### REST read side (B2)

`reblogged` on a projection is read from the viewing User's active rows with a kept wrapper: `StatusRelationshipsPresenter` adds one more sub-select to its existing statement (no extra round trip, no per-status query), keyed by `ExternalBridge::Viewer.user_id` and the Account id of the request. `REST::StatusSerializer` does the same lookup when no relationships object is given (single status, streaming payload rendered for the owner). So `GET /api/v1/statuses/:id`, home and list timelines, bookmarks, favourites, the compact serializers, and every other call site of the presenter agree, and a second User of the same Account reads `false`. The flag and the policy are not read: the state is what exists. Account-scoped `reblogged` and `reblogs_count` of a normal status are unchanged. The projection's `reblogs_count` stays its own stored value (0); it is not the count of the reference note.

### API

```
POST /api/v1/statuses/:projection_id/reblog          -> 200 Status (the wrapper)
POST /api/v1/statuses/:projection_id/unreblog        -> 200 Status (the projection, reblogged=false)
```

Create returns the wrapper: `id` is the wrapper id, `visibility` the policy scope, `reblog` the reference note (its `content` is the E4-A allowlist text), and no `fedibird_external` anywhere. Unreblog returns the projection as the owner sees it (`visibility: "direct"`, `visibility_ex: "external"`, `reblogged: false`).

Errors: `404` for a non-owner, nil user, admin, forged marker, and other-User; `401` without a token; `403` for a read-only token and for `feature_disabled`, `tester_only`, `consent_required`, `user_not_functional`; `422` for `visibility_mismatch`, `circle_rejected`, `scope_rejected`, `reference_modified`, `reference_broken`, `reference_already_boosted`, `canonical_url_invalid`; `409` for `reference_conflict`, `policy_changed`, `share_outdated`; `422` also for `projection_not_canonical`. Body: `{"error": "<code>"}`.

### Unsupported or deferred

Standard clients cannot reach this unless they can send the projection id: it is `visibility: direct`, `visibility_ex: external`, so stock clients do not show a boost button for it. E4-C decides the REST `unlisted` presentation, the WebUI boost button, the consent UI, and client compatibility. Also not done: Bluesky native repost, reply, quote, and reference conversion. The Streaming and WebUI-reducer part of issue #558 is **not done in E4-B** and is a gate below.

### Gates before `external_bridge_link_sharing` or its tester list is turned on

E4-B is the server-side foundation, delivered with the flag off. The flag and the tester list must stay off until each item below is done and verified. These are not optional follow-ups.

1. **Streaming and reducer consistency of `reblogged` (the open part of issue #558).** Nothing publishes an event when the share state of a projection changes, and the WebUI reducer has no protection against an older stream frame overwriting a newer REST `reblogged` (`E3` renders a projection for its owner with the state at render time). Required: a stream notification of the change to the owner's other sessions; a reducer rule that a status payload older than the state already applied never rolls `reblogged` back (a monotonic marker from the server, ordered with the E3 stream clock and reconnect boundary); the ids involved are the projection id, never the wrapper id or the reference note id. Minimum verification contract: User A and User B, including two Users of one Account; boost, Undo, boost again; REST response delayed behind a stream frame and stream frame ahead of the REST response; the original projection's `reblogged` while it is held in home, list, and Mix; ordinary Statuses unchanged. A hands-on test with the real UI may wait for the phase that ships the UI, but this must be passed before the flag is turned on.
2. **Remote receivers.** The Announce is at-least-once (see "Delivery boundary"), the activity id is stable, and nothing more is guaranteed. Create then Announce arrival order and the receivers' handling of a repeated Announce have not been tested against real remote servers. Record the result for the target software before turning the flag on.
3. **E4-C.** REST `unlisted` presentation, the boost button, the consent UI, and client compatibility. Until then the only way to reach this code is a direct API call.
4. **Environment checks not run so far.** Elasticsearch examples, the privilege-admin schema job, an `EXPLAIN` of the profile listing (`AccountStatusesFeed`) and of the `statuses` `BEFORE DELETE` trigger at production size.
5. **Timeline rebuild paths.** `populate_home` and `merge_into_home` leave the wrapper out; other readers of an Account's boosts that fill a timeline were only searched for, not tested.

### Operational stop points

- Stop new shares: `external_bridge_link_sharing` false, or empty the tester list, or revoke the policy. Existing shares stay and can be undone.
- Stop a pending Announce: any of the three above closes the row at announce time. To stop distribution at the queue, pause `ExternalBridge::LinkBoostAnnounceWorker`; nothing is lost, the row stays `announce_enqueued_at IS NULL`.
- Stop one announced share: unboost it. That is the Undo.
- Do not delete rows from `external_projection_link_boosts`. Roll back (`20261029120000` down) is refused while any row exists, for the same reason as E4-A.

## Still not implemented

- Changing the projection's standard visibility from `direct` to `unlisted` (E4-C).
- A boost button, settings UI, or consent UI (E4-C).
- Reply, quote, or reference conversion.
- Bluesky native repost, like, or reply.
- Turning the flag or the tester list on.
- A new `statuses` column or a backfill of existing projections.
