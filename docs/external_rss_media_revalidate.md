# External image revalidation

Issue #588, P3-A. A ready image is reused by URL digest, so a publisher that
replaces the bytes at the same URL would otherwise stay invisible. This pass
conditional-GETs images that are already due. It does not GET every image on
every feed refresh.

## When a request is made

An asset is due when it is a ready image, `revalidate_after` is blank or in
the past, and `validated_at` is blank or older than 24 hours. A refresh may
enqueue at most 2 of those (`MEDIA_REVALIDATE_PER_REFRESH`). The scheduler
runs every 15 minutes and returns immediately while
`Setting.external_bridge_rss` is off. The flag default is unchanged.

The scheduler query keeps only ready images that already have a row in
`external_media_asset_resources`, and only then applies `LIMIT`
(`MEDIA_REVALIDATE_BATCH`, 10). Unlinked rows, including images saved before
this link table existed, cannot occupy that batch. The pass still does not
scan every resource.

The job arguments are a resource id and the URL digest. The URL stays on
`external_resources.media_candidates`. `external_media_asset_resources`
records which resource still publishes that digest so the scheduler does not
scan every resource. Assets with no link are skipped. There is no URL
backfill.

`URLLock.exclusive` wraps the conditional GET. A second worker waits, then
sees the updated `validated_at` and does not GET again.

## Outcomes

| Response | Local file | Result |
| --- | --- | --- |
| 304 | present | Reuse. Validators are touched. The file stays ready. |
| 304 | missing | `state=failed`, `failure_code=local_missing`. Not ready. Projections keep the copies they already have. Recovery is an unconditional fetch, described below. |
| 200 | present, same fingerprint | Touch `validator_etag`, `validator_last_modified`, `validated_at`. |
| 200 | missing, or fingerprint changed | `ReplaceGeneration` stores the next generation, repoints projections in batches, then `MediaGc.plan_generation!` releases the previous file. A subscriber keeps the previous attachment until that subscriber's batch commits. |
| timeout, HTTP error, SSRF rejection | either | Keep the current file. `revalidate_after` backs off (15s, 30s, then 7 days). `failure_code` records the class of failure. |

## Generation swap

The new bytes are saved first, on a row whose digest is `incoming:{old id}`
and whose `generation` is the next generation id. That row is the checkpoint.
`logical_digest` on that row is the article URL digest (nullable, no default,
no backfill). `Sequence` indexes a projection by `logical_digest` as well as
by a public `url_digest`, so a subscriber who has already moved still
resolves the article URL to the new file. A subscriber who has not moved
still resolves it to the old file. `RSS::Media::Sync` treats the incoming
row and the public row as the same generation. A refresh, or a fetch of a
different image, does not delete the incoming link or copy the old file
back. The checkpoint still finishes on the next pass.

One pass then repoints at most `MEDIA_REPOINT_BATCH` (8) projections. The
new `MediaAttachment` and its `external_media_repoint_stages` row commit in
one transaction, before the short link transaction. That stage names the
file, the incoming asset, the projection, and the account and status. It is
the only proof that this swap may delete the file. The link transaction
plans the previous attachment for GC, inserts a new projection row, deletes
the previous projection row, and deletes the stage. The GC proof names that
previous row, so the row has to go away before the previous file can be
released. The asset row lock is not held across the copy.

If the link transaction rolls back, this worker expires the stage lease and
`MediaAttachment#destroy!` removes the file through Paperclip. A later pass
does that only for a stage whose lease has already lapsed, and only when no
projection link points at the file, the account still matches, and the
status still matches or purge has nullified it because that status is gone.
A live lease, or an attachment with no stage, is left in place. Nothing
here deletes by description, content type, or creation time, and nothing
computes a storage directory to remove.

Purge deletes the projection and nulls `media_attachments.status_id`. The
stage's projection and asset foreign keys are `ON DELETE SET NULL`, so the
proof row stays. `status_id` on the stage is not a foreign key and still
names the status that was purged. `MediaGc.drain!` sweeps stages whose
prepare lease and `available_at` are both due, and the media GC scheduler
starts that pass when any such stage exists. A subscriber list that never
calls repoint again still loses the prepared file after the lease. A
compose upload has no stage, so the sweep does not see it.

The sweep claims at most one batch. A row that cannot be deleted keeps its
stage, stores `failure_code`, and moves `available_at` forward by the same
backoff as media GC. After `MediaGc::MAX_ATTEMPTS` the state is `retained`:
the proof stays, and the row leaves the sweep. `more` is set only when
another due row was already behind this batch, so a full batch of failures
does not requeue the worker every second. A claim that dies mid-release
hides the row until `claimed_until`, then the next pass can take it.

A kill after that transaction commits leaves the stage for the sweep. A
kill inside the transaction leaves no attachment row and no stage.
Paperclip can write the object before the commit. Those bytes have no row.
This increment does not scan storage for them. The follow-up gate, not
built here, is a reservation written before the upload that stores the
Paperclip key, so a later pass can delete that key through Paperclip.
Until that gate exists there is no safe automatic or manual reclaim for
those orphans. A process kill and a real object store (S3 or similar) were
not exercised. The local spec checks that Paperclip removed a file whose
stage had committed, and that a rolled back stage insert does not leave an
attachment row.

`MediaGc.plan_generation!` runs only when no projection still references the
old row. The old digest becomes `superseded:{id}` in that same transaction,
and every resource link on the old row is copied to the new row when that
resource's current `media_candidates` still contain this image URL. A link
whose resource no longer lists the URL is left behind and disappears with
the old row. The triggering resource is included in that check.

If projections remain, the pass returns without retiring the old row. The
old row stays `ready`, keeps its `validated_at`, and keeps the resource
links. The pass enqueues `MediaGenerationContinueWorker` with the resource
id and the digest. That worker has no unique lock, so it can enqueue the
next batch before it returns. It loads the checkpoint and continues without
another GET. If that enqueue is lost, the 15-minute scheduler still selects
the old row and runs the same resume.

A process kill in the middle does not plan the old file. The old row is
still ready and still referenced. If a generation intent is inserted
anyway, release retains it (`still_referenced`) and the file stays.
Calling the worker again finishes the same incoming row and does not
allocate another generation for that swap.

## Missing file after 304

A 304 does not contain a body, so the conditional GET cannot rebuild a
missing shared file. The asset is `failed` and drops out of the revalidate
scheduler, which only selects `ready` images. Projection attachments are
not removed.

Recovery does not send `If-None-Match` or `If-Modified-Since`. After the
URL lock is released, the revalidate worker enqueues `MediaFetchWorker`
with the resource id, the resource's current `media_revision`, and the
digest. `ImageFetch` is called with no validators, so a publisher that
keeps answering 304 to the conditional request still returns the body.
`AssetStore.store!` writes that body onto the same asset row and marks it
ready.

If that job is lost, the next feed refresh that materializes the resource
enqueues the same worker. `Materialize#project` calls `Media::Sync.enqueue!`
on that pass, including when the text and `media_revision` are unchanged.
`enqueue!` queues a fetch for an image that is not `ready`. The refresh
that includes the item is the pass that reaches it.

`ETag` and `Last-Modified` are stored only after a successful 200. They are
sent as `If-None-Match` and `If-Modified-Since`. Content type, byte size,
pixel limits, SSRF, DNS, redirects, and authenticated URLs use the existing
image fetch rules.

A generation swap notifies the owning status stream and deletes
`statuses/:id` from the cache even when `media_revision` did not change.
INFO logs contain the asset id and the failure code, not the URL or a token.

## Data

Migration `20261102140000` adds nullable validator columns and constant
defaults (`generation` 1, `revalidate_attempt` 0). Migration
`20261103140000` adds nullable `logical_digest` with no default. Migration
`20261103150000` adds `external_media_repoint_stages`. Migration
`20261103160000` makes the projection and asset ids nullable and changes
those foreign keys from cascade to nullify. It also indexes
`(lease_until, id)`. Migration `20261103170000` adds `state`,
`available_at`, `attempt_count`, `failure_code`, and the claim columns, plus
a partial index on due pending rows. PostgreSQL 11+ does not rewrite
existing asset rows for the nullable digest. The stage table is empty on
deploy. `down` of `20261103160000` deletes only stage rows that already lost
a parent, then restores the cascade keys. `down` of `20261103170000` drops
the scheduling columns. Neither deletes files.

The partial index
`index_ext_media_assets_on_image_revalidate` is `validated_at ASC NULLS FIRST`
where `state = 'ready' AND kind = 'image'`. `lock_timeout` is 5 seconds.
`down` drops the columns, the index, and `external_media_asset_resources`.
It does not delete files. No feature flag was added.

## Not in this increment

Picture/srcset fallback is P3-C. Browser playback on iOS Safari, PWA, and
Chrome is P3-D and is not claimed here. S3 storage and a live publisher CDN
were not exercised.

Follow-up gate: Paperclip bytes written before the prepare transaction
commits have no stage and no attachment row. Do not scan the storage tree.
The gate is a reservation row that records the storage key before the
upload, then a Paperclip delete of that key only. Process kill and S3 are
still unverified, so this gate is not claimed as done.
