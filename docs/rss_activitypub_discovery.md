# RSS/Atom ActivityPub discovery (issue #605)

This is a **public metadata-only probe**, not an ActivityPub bridge. RSS
resources and owner-private status projections remain separate records.
Projection statuses keep their existing URI-null and non-federating rules.
Nothing is imported, dereferenced recursively, signed, or republished.

## Evidence model

Three facts are stored separately. None of them implies the others.

- **host_activitypub_supported** (`unknown` / `supported` / `not_advertised`)
  is only the feed host's NodeInfo self-report. `supported` means that host's
  NodeInfo document listed the `activitypub` protocol. It does not mean this
  RSS document is produced by that implementation. A transient NodeInfo error
  leaves the previous value in place; `activitypub_instance_state` records
  `advertised`, `not_advertised`, `unavailable`, `inaccessible`, or `error`.
- **activitypub_feed_attribution** (`unknown` / `attributed`) is the only
  field that means "this RSS looks like an ActivityPub implementation's
  feed". It is computed from the feed document: the generator names a known
  ActivityPub project **and** an entry is identified on the same host (its
  id/guid, canonical URL, or explicit ActivityStreams link). NodeInfo and a
  verified item on another server are not inputs.
- **activitypub_state** on a source is `unknown`, `hinted`, or
  `items_verified`. It is never `verified`. `items_verified` means at least
  one linked URL returned an ActivityStreams object, which may be a different
  server (an RSS aggregator). `hinted` is only a generator name or a typed
  link.

On each resource:

- **activitypub_state `verified`** means the candidate URL returned an
  ActivityStreams 2.0 content object (Note, Article, and the other allowed
  types) with the AS2 context and an expected content type. It does **not**
  mean the JSON `id` was fetched or proven equal to the candidate URL.
- **activitypub_object_id** is that document's self-declared id, stored
  verbatim after checks for length, an http(s) URI, credentials, and private
  address literals. Fragments and ordinary query strings are kept. Fetch URLs
  still go through the strict RSS item canonicalizer, which is a different
  rule.
- **activitypub_object_id_status `self_reported`** marks that id. Nothing in
  this change sets a dereferenced status. Later code must not treat the id as
  a confirmed IRI.

A 401/403 is `inaccessible`, not evidence that the remote server lacks
ActivityPub. Changing the candidate URL clears state, object id, object id
status, object type, and check times in one conditional `UPDATE` keyed by the
previous candidate digest and `activitypub_evidence_version`. The probe claim
bumps that version, and the completion writes only if the digest and the
post-claim version are still current.

## What gets probed

Explicit `rel=alternate` / `rel=self` links of type `application/activity+json`
or `application/ld+json` are probe candidates. Ordinary permalinks are not.
A feed keeps at most two ordinary candidates, or eight when
`host_activitypub_supported` is `supported`. Replacing the URL in an existing
sample slot does not open another slot. For a host that has not advertised
ActivityPub, the first ordinary `unavailable` or `error` sets
`activitypub_ordinary_blocked_until` thirty days out and further ordinary
GETs wait. Explicit links are not covered by that cooldown.

Each source run performs at most two item GETs, explicit candidates first.
NodeInfo is at most two GETs (well-known, then a same-origin 2.1/2.0 schema)
and is independent of the item cap.

## Operations

Additional HTTP requests are **off by default**:

    Setting.external_bridge_rss_activitypub_discovery = true

The normal RSS bridge master switch and its tester allowlist must also permit
the source. The separate Sidekiq pull worker checks again at execution time.
A claimed item is leased for 30 minutes by bumping
`activitypub_evidence_version` and pushing `activitypub_next_check_at`
forward. Successful or merely unavailable entries wait seven days.
Inaccessible or error entries wait one day. Normal feed refresh or subscribe
schedules subsequent work. There is no walk of every historical permalink.

Due checks use partial indexes on `external_resources`:

- `index_external_resources_on_ap_probe_due` for the next explicit or
  ordinary row whose `activitypub_next_check_at` is due
- `index_external_resources_on_ap_sample` for the stable ordinary sample
- `index_external_resources_on_ap_item_verified` for "any verified item?"

NodeInfo requests use a same-origin fetch policy. Each redirect hop is
checked **before** it is requested. A public cross-origin 302 is not
followed, so that host is not contacted and does not escape the per-host
budget. Private addresses are still rejected by `Request` on every hop.

The fetch uses the existing public Request implementation: redirect and DNS
private-address checks, no credentials, no signatures, a separate 10
requests/hour per-host budget, a 64 KiB NodeInfo ceiling, a 256 KiB object
ceiling, and tight timeouts. ActivityStreams JSON is parsed locally, without
retrieving remote JSON-LD contexts. Error classes, not remote bodies, are
logged.

This remains conservative. Some real AP URLs need a signed GET or a discovery
mechanism not implemented here. Those stay unknown, inaccessible, or
unavailable. HTML `rel=alternate` discovery, assigning `Status.uri`, synthetic
actors, and any user-facing toggle are out of scope.

Useful Rails console inspection:

    ExternalSource.find(id).slice(
      'host_activitypub_supported', 'activitypub_instance_state', 'activitypub_software',
      'activitypub_feed_attribution', 'activitypub_state', 'activitypub_hint'
    )
    ExternalResource.find(id).slice(
      'activitypub_state', 'activitypub_candidate_url', 'activitypub_object_id',
      'activitypub_object_id_status', 'activitypub_object_type', 'activitypub_checked_at'
    )

No migration backfill or probe runs on deploy. A normal refresh records
candidates. Probing runs only after the setting is turned on for tester RSS
users.
