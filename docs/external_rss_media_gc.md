# External media garbage collection

Issue #588, P3-B. Projection purge deletes statuses with SQL. PostgreSQL then
removes `external_status_projections` and `external_projection_attachments`
and sets `media_attachments.status_id` to null. The files are not part of
that statement. The ids used to live only in the process that committed the
DELETE, so a kill between commit and `destroy!` left the files behind with
no retry.

## What is eligible

A file is eligible only when a row in `external_media_gc_intents` says so.
The plan is inserted in the same transaction as the DELETE, or in the same
transaction that drops a projection link during an attachment replacement,
and only for ids that are still linked from `external_projection_attachments`
at that moment.

An attachment intent records the owner account, the status id, and the
projection-attachment id from that link. Release deletes the
`MediaAttachment` only when all of the following are still true:

| Reason | Required at release |
| --- | --- |
| `projection_purge` | Captured status no longer exists, `status_id` and `scheduled_status_id` are null, no projection link remains, `account_id` matches, the Paperclip path belongs to this row |
| `attachment_replaced` | `status_id` is still the captured external projection, no projection link remains, owner matches, Paperclip path belongs to this row |
| `external_media_asset` (`projection_purge`, `asset_unreferenced`, `generation_replaced`) | No `external_projection_attachments` row references the asset, the URL download lock is not held, the Paperclip path belongs to this row |

`status_id IS NULL` is not a deletion criterion. `Scheduler::MediaCleanupScheduler`
still removes ordinary unattached uploads older than a day. This GC does not
call that scope and does not widen it.

Compose uploads are not planned: they have no projection link. A pending
intent whose proof columns are missing, whose owner does not match, or whose
captured status is still a non-projection status is marked `retained` and the
file stays.

Shared assets used by another subscriber are `retained`. A later purge of the
last subscriber inserts a new pending intent. `plan_generation!` is the hook
a replacement generation uses; a referenced asset is retained.

## Crash, retry, and duplicates

`MediaGc::CommitHook` runs on commit. `rolledback!` does not delete files.
If the process dies after the database commit and before the hook finishes,
the intent stays `pending`. Nothing on the Sidekiq payload is a status id.
`ExternalBridge::RSS::MediaGcWorker#perform` takes no arguments and claims
at most 25 due rows (`FOR UPDATE SKIP LOCKED`).

The default grace is 60 seconds (`EXTERNAL_MEDIA_GC_GRACE_SECONDS`, clamped
to 0..3600). The commit hook does not wait. The recovery worker does, so it
does not race the process that is still releasing the batch. A refused or
lost enqueue is picked up by `Scheduler::ExternalBridgeRSSMediaGcScheduler`
(every minute). The scheduler is not gated by the ExternalBridge flags: it
only finishes plans that a purge or replacement already committed.

Attempts back off over 1 minute, 5 minutes, 15 minutes, 1 hour, and 6 hours.
The eighth failure sets `state` to `failed` and stops. The file is kept.
`rake external_bridge:media_gc:requeue_failed` puts those rows back to
`pending` without deleting anything.

Two workers, or a hook plus a worker, claim different rows. A second pass
over a target that is already gone marks the intent `released` with
`last_error_code` `missing`.

Resolved (`released` and `retained`) rows older than 7 days are deleted in
batches of 500 by the scheduler. `failed` and `pending` rows stay.

`external_subscription_deletion_id` is a correlation id, not a foreign key.
Unsubscribe retention cleanup cannot drop a plan or wait on it.

## Failure codes

| Code | Result |
| --- | --- |
| `still_referenced`, `projection_link`, `live_status`, `status_still_present`, `scheduled_status`, `owner_mismatch`, `not_projection`, `unproven`, `storage_mismatch` | `retained`. File kept |
| `url_locked`, `lock_unknown`, `storage_error`, `database_error`, `unexpected_error` | `pending` with backoff, then `failed` |
| `missing` | `released` |

Logs are `[ExternalBridge::MediaGc]` lines with action, target type, target
id, reason, and error code. They do not include URLs, tokens, lease tokens,
or file names. The scheduler line is counts only.

## Operations

```
bundle exec rake external_bridge:media_gc:diagnose
bundle exec rake external_bridge:media_gc:requeue_failed
```

`diagnose` prints JSON counts (`pending`, `due`, `released`, `retained`,
`failed`, `by_reason`, `by_error`) and up to 20 pending decisions. It does
not delete files. There is no rake task that deletes files. Deletion runs
only in the commit hook and the worker, after the checks above.

The migration `20261102120000` creates an empty table and two partial
indexes. It does not update existing media rows. Rolling it back drops the
plans and does not delete files.

## Not in this increment

ETag revalidation, picture/srcset fallback, and browser playback checks are
separate changes. `plan_generation!` is unused until a replacement asset
exists. iOS Safari was not exercised here.
