# Group federation delivery observation

Status: observation only. Default **off**.

This records separate evidence for a public post from an allow-listed
local admin to one saved remote Group actor. It does not decide that
the remote community accepted the post, and it does not show a result
to ordinary users.

Fedibird local groups are the comparison case in the manual procedure
below. Their normal delivery is not written to this observation record.

## Do not collapse the stages

| Stage | Meaning |
|---|---|
| Local status created | The status row exists on this server |
| Delivery queued | The group actor inbox job was enqueued |
| HTTP attempted | This server sent an HTTP request to that inbox |
| HTTP 2xx observed | That response code was 200–299 |
| Group Announce observed | Existing ActivityPub ingest stored a reblog of this status by that group |
| Community listing | A person looked at the remote community and checked the page |

HTTP 2xx is not acceptance. Announce means the group redistributed
something this server stored as a reblog. It does not prove the current
web page still shows the post. A missing Announce is not a rejection.
A post disappearing on the remote server is not the same event as an
HTTP delivery failure.

No automatic test, script, or agent may create, edit, or delete a post
on a public Mitra, NodeBB, Lemmy, or PieFed community. Those steps are
manual and require the community's permission.

## Activation

```bash
GROUP_FEDERATION_OBSERVATION_ENABLED=true
GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS=1
```

`GROUP_FEDERATION_OBSERVATION_ENABLED` must be the string `true`. Any
other value, including an unset variable, stays off.

`GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS` is a comma-separated list of
local account ids. An empty list starts nothing. An id is used only
when that account is local and its user has `admin` set. Posts by
anyone else are not collected.

Turning the flag off stops new records. A job that already carries an
observation id can still update that record. Ordinary public posts,
direct messages, followers-only posts, and local-group delivery are
not eligible.

## Redis record

No PostgreSQL table is added. One key per status and target group:

```text
group-post-observation:v1:status:<status_id>:target:<group_account_id>
```

TTL is 14 days, refreshed on each update. A second delivery for the
same pair does not create a second record. Updates are atomic. When
the key is gone, later reads are unknown rather than success or
failure.

Stored fields:

| Field | Notes |
|---|---|
| `schema_version` | `1` |
| `status_id` | String id |
| `target_account_id` | Remote group account id |
| `adapter` | `mitra_group`, `nodebb_group`, `lemmy_group`, `piefed_group`, or null |
| `activity_type` | `Create` for this distribution path |
| `queue_observed` | True only after enqueue returns |
| `attempt_count` | HTTP attempts. Suppression and circuit stops do not increment it |
| `last_http_status` | Last HTTP status that is allowed to replace the previous one |
| `http_2xx_observed` | Sticky. Later errors do not clear it |
| `http_2xx_at` | UTC time of the first observed 2xx, `YYYY-MM-DDTHH:MM:SSZ` |
| `last_attempt_outcome` | See the table below |
| `terminal_failure` | True only after Sidekiq retries for that job are exhausted |

Not stored: post text, content warning, media, cookies, Authorization,
HTTP signatures, inbox credentials, ActivityPub JSON, or raw exception
messages.

The record is inserted before `ActivityPub::DeliveryWorker.push_bulk`.
Only the job whose inbox is the group actor inbox receives
`group_delivery_observation`. Follower inboxes, relays, and mention
delivery do not. If that inbox is also a follower inbox, delivery stays
deduplicated and that single job carries the id.

### HTTP classification

`@performed` is not success. Unsalvageable responses set it too.

| Condition | `last_attempt_outcome` |
|---|---|
| 200–299 | `http_success` |
| 4xx that will not be retried, including 501 | `http_unsalvageable` |
| Retryable HTTP error, including 401, 408, 429, and 5xx | `http_retryable` |
| Timeout | `timeout` |
| Connection or TLS failure | `connection_failure` |
| Stoplight open | `circuit_interruption` |
| `DeliveryFailureTracker` skipped the request | `availability_suppression` |
| No request and no classified error | `not_attempted` |

Sidekiq retry settings are unchanged. A 5xx or timeout on an
intermediate attempt leaves `terminal_failure` false.
`availability_suppression` does not set `last_http_status` and does not
increment `attempt_count`. A Redis or observer error must not fail a
delivery that would otherwise succeed, and must not replace a retryable
delivery error.

An older `request_started_at` cannot replace a newer last outcome or
clear `http_2xx_observed`.

## Announce evidence

The reader checks the status row the existing
`ActivityPub::Activity::Announce` path already stores:

```ruby
Status.where(account_id: group.id, reblog_of_id: status.id).where.not(uri: [nil, '']).exists?
```

It counts only when all of these are true:

- the original status is local
- `audience_account_id` is this group
- the group is a remote account
- the group actor URI is saved
- the reblog belongs to that group and has a URI

A boost by anyone else, including another group, does not match.
`group_announce.observed = false` with `evidence = "none"` means no
such row was found. It does not mean the group refused the post.

Some software, including Lemmy, can put a Create activity inside
`Announce.object` instead of the Note URI. This version does not change
the receiver. If that shape is not stored as a reblog of the local
status, the reader stays at `evidence = "none"`. Keep the payload for a
separate follow-up. Do not infer acceptance from an unverified payload.

## Rails console

```ruby
status = Status.find(12345)
PostingContext::GroupPostObservationReader.new.call(status)
```

Example shape:

```json
{
  "status_id": "12345",
  "target_account_id": "456",
  "adapter": "lemmy_group",
  "local_status": "created",
  "delivery_queue": "observed",
  "transport": {
    "last_outcome": "http_success",
    "http_status": 202,
    "http_2xx_observed": true,
    "attempt_count": 1,
    "terminal_failure": false
  },
  "group_announce": {
    "observed": false,
    "evidence": "none"
  },
  "remote_acceptance": "unknown",
  "community_listing": "not_verified"
}
```

`delivery_queue` is `unknown` when the key is missing, `not_queued`
when the record exists but enqueue did not succeed, and `observed`
after enqueue. `remote_acceptance` stays `unknown`.
`community_listing` stays `not_verified` until a person fills it in
outside this record. The reader does not add a Web UI or a public API.

## Manual interoperability procedure

Run this separately for Mitra, NodeBB, Lemmy, and PieFed, on a
community that has allowed test posts. Repeat the comparison mentally
for a Fedibird local group: that post should still behave as it does
today, and it should not create one of these Redis records.

Before posting:

1. Confirm federation is enabled on both servers.
2. Confirm the test account may post in that community.
3. Record the group actor URI and actor inbox URI.
4. Record Fedibird's discovery adapter (`mitra_group`, `nodebb_group`, `lemmy_group`, or `piefed_group`).
5. Record NodeInfo `software_name`.
6. Confirm the composer will send a public post.

Then, as the allow-listed admin, manually:

1. Create one public test post.
2. Record the local status id and Note URI.
3. Read `PostingContext::GroupPostObservationReader` for that status.
4. Record the HTTP outcome and status code.
5. Search for a group Announce using the reader, and record whether a reblog row exists.
6. Open the remote community and record whether the post is listed.
7. Record the remote post URL if one is visible.
8. Separately edit and delete, then record Update and Delete delivery and what the remote page shows.

Judge every stage on its own:

| Verdict | Use when |
|---|---|
| `pass` | That stage was checked on the live server |
| `fail` | That stage has explicit contrary evidence |
| `inconclusive` | The check ran but the evidence is not enough |
| `not_tested` | The stage was not run |
| `not_applicable` | The stage does not apply to this target |

Suggested rows: local status, queue, HTTP attempt, HTTP 2xx, group
Announce, community listing, Update delivery, Update reflection,
Delete delivery, Delete reflection.

Leave unrun targets as `not_tested`. Do not copy a Mitra result onto
Lemmy. Do not mark `remote_acceptance` or `community_listing` from HTTP
2xx or from Announce alone.
