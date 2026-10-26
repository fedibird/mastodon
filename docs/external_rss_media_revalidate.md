# External image revalidation

Issue #588, P3-A. A ready image is reused by URL digest, so a publisher that
replaces the bytes at the same URL would otherwise stay invisible. This pass
conditional-GETs images that are already due. It does not GET every image on
every feed refresh.

## When a request is made

An asset is due when it is a ready image, `revalidate_after` is blank or in
the past, and `validated_at` is blank or older than 24 hours. A refresh may
enqueue at most 2 of those (`MEDIA_REVALIDATE_PER_REFRESH`). The scheduler
runs every 15 minutes, takes at most 10 (`MEDIA_REVALIDATE_BATCH`), and
returns immediately while `Setting.external_bridge_rss` is off. The flag
default is unchanged.

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
| 304 | missing | `state=failed`, `failure_code=local_missing`. Not ready. |
| 200 | present, same fingerprint | Touch `validator_etag`, `validator_last_modified`, `validated_at`. |
| 200 | missing, or fingerprint changed | `ReplaceGeneration` writes a new asset, repoints every projection, then `MediaGc.plan_generation!` releases the previous file. The previous attachment stays visible until that commit. |
| timeout, HTTP error, SSRF rejection | either | Keep the current file. `revalidate_after` backs off (15s, 30s, then 7 days). `failure_code` records the class of failure. |

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
