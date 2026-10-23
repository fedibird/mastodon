# External link sharing

Parent plan: issue #541. E4 plan: issue #555. This document is the E4-A contract, issue #556.

Related contracts:

- `docs/external_status_visibility.md` — projection visibility, the read predicate, and the `direct` / `visibility_ex=external` mask.
- `docs/external_feed_routing.md` — E3 home and list delivery. It does not publish a projection.

E4-A is not a rollout. `external_bridge_link_sharing` and `external_bridge_link_sharing_testers` ship false and empty. Generation fails closed while they are off. This slice does not convert boost, unboost, reply, or quote, does not change a projection's REST visibility, and does not add a boost button.

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
8. After that transaction commits, `PublishReference` enqueues `LinkReferencePublishWorker`. A returned jid means Sidekiq accepted the job and `next_recovery_at` is set 30 minutes ahead. `nil` means it did not: `published_at` and `next_recovery_at` stay null, and nothing is treated as queued. The worker locks the mapping row, calls `PublishStatusService`, then sets `published_at`. The projection is not passed to distribution, ActivityPub, webhooks, or the public search index.
9. A later ensure sees `published_at` and does not enqueue again. `PublishStatusService`'s Redis key still expires after 7 days for ordinary statuses. That key is not the reuse decision for a reference. Deleting it, or waiting it out, does not distribute the same note again.
10. If the worker raises before `published_at` is written, Sidekiq retries that job. If the process stops after commit and before an accepted enqueue, no job exists. `Scheduler::ExternalBridgeLinkReferencePublishScheduler` runs every 5 minutes and selects at most 20 rows. It does not call ensure, and it does not read the feature flag or the current policy. Those gates apply when the note is created. A note already inserted is still distributed after the flag is turned off or consent is revoked. Broken mappings, discarded notes, projection statuses, and account mismatches are left unpublished. A second pass, or two workers, take the same row lock and call `PublishStatusService` once.

The scan orders by `next_recovery_at ASC NULLS FIRST, id`. Unvisited rows come first. A row with an accepted jid is not selected again until `next_recovery_at`. That hold is 30 minutes, which covers more than four 5-minute passes, so a job that sits in Redis is not pushed again on every pass. A nil jid or a Redis connection error records `next_recovery_at = now` and creates no job. The next pass continues with rows that are still null, then comes back to the refused rows. After the hold expires, a head that never finished can be tried once more. That later try is not a new job every pass.

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

## What E4-A does not implement

- `POST /api/v1/statuses/:id/reblog` and unboost. `ReblogService` still calls `Guards.reject_target!`.
- `reblogged` on the projection, or a boost button.
- Changing the projection's standard visibility from `direct` to `unlisted`.
- Reply, quote, or reference conversion.
- Bluesky native repost, like, or reply.
- A settings UI. Consent is the policy service only.
- Turning the flag or the tester list on.
- A new `statuses` column or a backfill of existing projections.
