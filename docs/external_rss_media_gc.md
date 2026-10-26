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

An attachment intent records the owner account, the status id, the
projection id, and the projection-attachment id (`source_attachment_id` is
that link id, not a second media id). The same transaction inserts
`external_media_gc_proofs`. A trigger copies the live link's attachment,
projection, owner, and status onto that row and rejects later changes to
those columns. The proof has no foreign key, so it survives the purge.

Release deletes the `MediaAttachment` only when the intent matches that
proof and all of the following are still true:

| Reason | Required at release |
| --- | --- |
| `projection_purge` | Captured status no longer exists, `status_id` and `scheduled_status_id` are null, no projection link remains, `account_id` matches the proof, the Paperclip path belongs to this row |
| `attachment_replaced` | No projection link remains, owner matches the proof, Paperclip path belongs to this row, and either `status_id` is still the captured external projection, or that status is gone and `status_id` is null |
| `external_media_asset` (`projection_purge`, `asset_unreferenced`, `generation_replaced`) | No `external_projection_attachments` row references the asset, the URL download lock is not held, the Paperclip path belongs to this row |

`status_id IS NULL` is not, by itself, a deletion criterion. A replacement
intent may release a file in that state only after the captured projection
status has been deleted and the proof still names that same attachment.
`Scheduler::MediaCleanupScheduler` still removes ordinary unattached uploads
older than a day. This GC does not call that scope and does not widen it.

Compose uploads are not planned: they have no projection link, and the proof
trigger will not bind a row to an id that link does not have. An intent
with no matching proof, a mismatched projection or owner, or a captured
status that is still a non-projection status is marked `retained` and the
file stays.

Shared assets used by another subscriber are `retained` for that intent.
Every transaction that drops a link also inserts
`external_media_gc_asset_rechecks`. That insert is not covered by the
pending-intent unique index, so a second purge is kept even when its intent
insert conflicts. After commit, a recheck whose asset is still linked is
closed. A recheck whose asset has no links inserts a new pending intent
(the earlier `retained` row no longer occupies the unique index) and
releases it. `plan_generation!` writes the same recheck; a referenced asset
is retained.

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

Resolved (`released` and `retained`) intent rows and done rechecks older
than 7 days are deleted in batches of 500 by the scheduler. A proof is
deleted in that same pass once its attachment is gone and no `pending` or
`failed` intent names its link id. `failed` and `pending` intent rows stay.

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

The migration `20261102120000` creates an empty intent table and two partial
indexes. `20261103120000` adds `captured_projection_id`, the proof table,
the proof trigger, and the asset-recheck table. Neither updates existing
media rows. Rolling them back drops plans and proofs and does not delete
files. `20261103120000` refuses to run when an attachment intent is already
stored.

## Assumptions and forbidden operations

Planning is allowed only through `MediaGc::Plan`, inside the purge,
replacement, or generation transaction, and only for ids that
`external_projection_attachments` still points at. The application does
not insert intents, proofs, or rechecks from a controller or a rake task.

These statements are forbidden. They can name a file the planner would
have skipped:

- `INSERT` into `external_media_gc_intents` for a media id that was not
  returned by the projection-attachment join
- `INSERT` into `external_media_gc_proofs` for a link id that does not
  exist. The trigger rejects that statement
- `UPDATE` of a proof's link, attachment, projection, owner, or status.
  The trigger rejects that statement
- `INSERT` into `external_projection_attachments` that points a compose
  upload at a projection so a later proof will bind to it
- Deleting a proof in order to insert another one after the link is gone.
  The trigger still requires the live link, so the new insert fails; do
  not disable the trigger to make it succeed

A database role that can insert a projection-attachment row for an ordinary
upload, insert a proof while that row exists, delete the link, and insert
an intent can still name that upload. That is outside the application
path. Operators do not run those statements, and this GC does not scan
`media_attachments` for `status_id IS NULL`.

A corrupted intent whose stored ids do not match `external_media_gc_proofs`,
or whose proof does not match a link or projection that is still present,
is `retained` with `unproven`. Non-null proof columns are not enough.

## Not in this increment

ETag revalidation, picture/srcset fallback, and browser playback checks are
separate changes. `plan_generation!` is unused until a replacement asset
exists. iOS Safari was not exercised here.
