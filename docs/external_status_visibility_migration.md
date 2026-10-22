# External projection visibility migration

E2 operator runbook for issue #544. Read `docs/external_status_visibility.md` first. This procedure stores new external projections as visibility 201 and moves existing projection rows from 200 to 201 without creating a new status id.

It does not enable home, list, or streaming delivery. It does not publish a link note. It does not turn the switch on by itself. Merging the pull request is not a deploy and it is not permission to migrate production.

## What changes for a person

| State | Standard visibility | visibility_ex | Personal timeline | Same id still opens from |
| --- | --- | --- | --- | --- |
| Ordinary personal post | direct | personal | unchanged | the personal timeline and the post |
| Legacy projection, before migration | direct | personal | still listed for the owner | the subscription list, the post, favourites, bookmarks |
| External, after migration or a new insert while the switch is on | direct | external | not listed | the subscription list, the post, favourites, bookmarks |

Another User on the same Account still cannot read the row. An open browser can keep the old label until reload. This command does not push `status.update`.

## Switch

`external_bridge_external_visibility` defaults to false.

```ruby
Setting.external_bridge_external_visibility = true
Setting.external_bridge_external_visibility = false
```

False means new projection inserts stay `visibility: personal`. True means `ProjectionWriter#create!` inserts `visibility: external`. Neither value rewrites existing rows. RSS refresh of an existing row updates text and the marker only. The RSS and AT Protocol flags and tester allowlists are separate. The key is not on the user preference screen and not on the admin settings form.

If the switch is on and this database cannot store an external projection, the insert raises `external_visibility_database_not_ready`. It does not save a personal or public status instead.

## Deploy order

1. Confirm every web, Sidekiq, and related reader is already running E1 or newer, so visibility 201 is known. This repository cannot check that for you.
2. Deploy this revision with the switch still false and run the new migration:

   ```sh
   bin/rails db:migrate
   ```

   The migration is `20261021180000_permit_external_visibility_projection_transition`. It replaces two functions. It does not rewrite `statuses`, add an index, or drop foreign keys. `lock_timeout` is 5 seconds.
3. Dry-run one owner. `user-id` is `users.id`, not `accounts.id`.

   ```sh
   bin/tootctl upgrade external-status-visibility --user-id USER_ID --limit 20
   ```

   Dry-run is the default. It does not change statuses, markers, Redis, Elasticsearch, or the checkpoint.
4. Turn the switch on. Confirm a new RSS item for an allowed tester is `visibility_ex=external`, and that an ordinary personal post is unchanged.
5. Apply a small batch. `--confirm-readers-ready` means you checked the readers. The process does not discover other processes.

   ```sh
   bin/tootctl upgrade external-status-visibility \
     --apply \
     --confirm-readers-ready \
     --user-id USER_ID \
     --limit 20 \
     --batch-size 20 \
     --checkpoint /var/lib/mastodon/external-visibility-user-USER_ID.json
   ```

   Then read that owner's status, subscription list, favourite, and bookmark. A second User of the same Account receives 404. The personal timeline no longer lists the migrated id.
6. Resume by repeating the same command and the same checkpoint. Raise `--limit` only after the small batch looks right. `--pause 0.2` waits between batches.
7. Verify. A finished checkpoint window is not instance completion.

   ```sh
   bin/tootctl upgrade external-status-visibility --verify --user-id USER_ID
   ```

   `verify scope_complete` means that scope had no legacy or invalid projection in the marker window, and the marker high-water mark did not move during the pass. It does not mean other users are done. Drop the user filter only when you intend to look at the whole instance:

   ```sh
   bin/tootctl upgrade external-status-visibility --verify
   ```

   `verify instance_complete` is the only completion claim. If the output says rows remain, or the watermark moved, run the migration again with a new checkpoint after writers are quiet, then verify again. A row that commits after the original high-water mark is left for that later pass.

## Command contract

| Flag | Meaning |
| --- | --- |
| (none) | Dry-run. |
| `--apply` | Write. Requires `--checkpoint`, `--confirm-readers-ready`, and the switch on. Refuses if the 200-to-201 function is missing. |
| `--verify` | Read-only second look. Cannot be combined with `--apply`. |
| `--user-id` | `users.id`. Empty, zero, or non-numeric is an error, not "all users". |
| `--subscription-id` | Optional. Must belong to `--user-id` when both are set. |
| `--batch-size` | Default 100. Maximum 1000. |
| `--limit` | Default 1000. Maximum 100000. Counts markers examined, including ones that are already external. |
| `--pause` | Seconds between batches. Default 0. Maximum 300. |
| `--checkpoint` | JSON file, mode 0600, replaced atomically. Required for apply. |
| `--lock-timeout` / `--statement-timeout` | Defaults `2s` and `30s`, inside each batch transaction only. |

The scan reads `external_status_projections.id` in keyset order up to the high-water mark taken at the start. It does not collect `statuses.visibility = 200` from the whole statuses table. Subscription state and the tester allowlist do not decide ownership. A paused subscription's existing projection is still a candidate. The command does not fetch, resume, or deliver.

Invalid shape stops the batch, rolls it back, and does not skip the row. There is no skip-invalid mode. A lock timeout or deadlock stops without moving the cursor past the row. `SKIP LOCKED` is not used.

Exit status: 0 finished the requested dry-run window, apply window, or a clean verify; 2 limit; 3 signal; 4 invalid row or lock conflict; 5 verify still sees legacy, invalid, or a moved watermark; 6 database committed and cache follow-up did not finish. Resume the same checkpoint after 3, 4, or 6. Exit 0 on an apply window is not instance completion.

The checkpoint stores the database name, the local domain, the scope, the direction `personal_to_external`, the high-water mark, the last completed marker id, and any pending batch ids. It does not store text, URLs, or secrets. Reusing it for another database, instance, scope, or direction is refused. A pending id list longer than 1000, or an id outside a PostgreSQL bigint, is refused as a bad checkpoint.

Apply holds `checkpoint-path.lock` from the existence check through the last save. A second apply or a dry-run that reads the same path while that lease is held is refused and does not replace the file. The lock is not a database transaction. If the process dies, the operating system releases it and the same checkpoint can be resumed. Two objects in one process cannot lease the same path together.

A saved pending batch is replayed before new rows, and only when it fits in this run's `--limit` and `--batch-size`. A larger pending batch is refused before any status write. Raise both limits to at least the pending count and run the same checkpoint again. The pending ids stay in the file. A stop signal is checked before that replay and before each new batch.

Cache follow-up runs only after the batch commits. It deletes `statuses/<id>` in Rails cache. When Chewy is enabled it bulk-deletes those status ids directly, in slices of 100, with `refresh=true`. Each slice is one bulk request. A deleted item is success. A bulk item is also success when its status is 404, its result is `not_found`, and it has no error object, or the error type is exactly `document_missing_exception`. The following GET is success only when its body names that id with `found: false`. A missing index or alias, a proxy or HTML 404, any other error type, a document that is still present, or a transport error leaves the pending batch in place and exits 6. Resume repeats the deletes, including slices that already succeeded. Ordinary statuses are not sent to that delete. This does not use the `:custom_sidekiq` root strategy, does not treat an enqueued job as finished, and does not clear the whole cache, rebuild feeds, or reindex the cluster.

`--verify` reads a clean window twice. Both reads count toward `--limit`. `scanned` is the number of marker reads, so a clean scope reports about twice as many reads as markers. `already_external` stays the first-pass count. If the second read does not fit in the remaining limit, the result is `limit_reached`, not completion.

## Stop

Stop the command with SIGINT or SIGTERM. The signal is checked between batches. A batch already inside its transaction is allowed to commit and finish its cache follow-up, or to roll back if that transaction fails. The command then exits without starting another batch. Resume the same checkpoint. Turn the switch off so new inserts return to personal:

```ruby
Setting.external_bridge_external_visibility = false
```

Rows already stored as external stay external. To stop new imports as well, turn off `external_bridge_rss` or remove testers. That is a separate operation. Do not delete the migrated statuses to undo the visibility change.

## Rollback

This migration is forward-only. There is no command that writes 201 back to 200 or to public.

`db:migrate:down VERSION=20261021180000` removes the permit and restores the E1 field guard. External rows may remain, and E1 code can still read them. It does not put the data back. E1's own down still refuses while any visibility 201 row exists, so you cannot migrate the database to a pre-E1 guard until those rows are gone by a later audited procedure.

Application rollback stops at a revision that understands E1. Older code does not know visibility 201.

## Database permit

`external_visibility_migrate_status(status_id)` is the only supported update path. It sets a transaction-local token for that id and updates `visibility` and `updated_at` only, then restores the caller's previous value of `fedibird.external_visibility_migration` before returning. A raised error or a cancelled query restores that value too. The function definition does not use `SET` on that parameter. Installing the function does not require superuser, `SECURITY DEFINER`, or `GRANT` on the parameter.

A database that already applied `20261021180000` from an earlier draft still has the old function until the follow-up migration runs. Apply it with the application role, not by granting that role superuser:

```sh
RAILS_ENV=test bundle exec rails db:migrate
```

That runs `20261022120000`, which replaces only `external_visibility_migrate_status`. It does not rewrite statuses and it does not put the `SET` clause back. `schema:load` of this revision installs the same function body and does not run the old clause.

The trigger rejects the statement unless the token matches that row's id and the current transaction id, the old and new shapes are a normal projection, a consistent marker exists, and no other column changed. Lock order inside a batch is marker id, then status id, which matches RSS refresh. Purge locks the status first, so a deadlock is possible; the batch stops and the checkpoint does not skip the row.

Direct `UPDATE` without the function still fails. Setting the token and also changing the text fails. A token for a different id fails. `fedibird.projection_status_delete` is not reused. Triggers are not disabled.
