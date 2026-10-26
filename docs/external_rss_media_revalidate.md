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
One pass then repoints at most `MEDIA_REPOINT_BATCH` (8) projections. Each
projection is its own transaction: copy the attachment, point the link at
the new generation, and plan the previous attachment for GC. The asset row
lock is not held across those copies.

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
defaults (`generation` 1, `revalidate_attempt` 0). PostgreSQL 11+ does not
rewrite existing rows for those defaults. The partial index
`index_ext_media_assets_on_image_revalidate` is `validated_at ASC NULLS FIRST`
where `state = 'ready' AND kind = 'image'`. `lock_timeout` is 5 seconds.
`down` drops the columns, the index, and `external_media_asset_resources`.
It does not delete files. No feature flag was added.

## Not in this increment

Picture/srcset fallback is P3-C. Browser playback on iOS Safari, PWA, and
Chrome is P3-D and is not claimed here. S3 storage and a live publisher CDN
were not exercised.
