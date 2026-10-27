# RSS/Atom ActivityPub discovery (issue #605)

This is a **public metadata-only probe**, not an ActivityPub bridge. RSS
resources and owner-private status projections remain separate records.
Projection statuses keep their existing URI-null and non-federating rules.
Nothing is imported, dereferenced recursively, signed, or republished.

## Evidence model

The two public cache tables expose:

- **external_sources**: activitypub_hint (weak feed marker) and
  activitypub_state (unknown / hinted / verified). A verified feed has at least
  one public item currently verified; it is NOT a claim that all entries have
  ActivityPub objects. Feed hints are based on known generator names or
  correctly typed alternate links and cannot establish verification.
- **external_resources**: activitypub_candidate_url, activitypub_state
  (unknown / verified / unavailable / inaccessible / error), object_id,
  object_type, checked_at and next_check_at. Only verified entries have an
  object identifier and type. A 401/403 response is *inaccessible*, not
  evidence that the remote implementation lacks ActivityPub.

For RSS 1.0, RSS 2.0 and Atom, candidate selection prefers an explicitly typed
ActivityStreams alternate link, then the public entry link, and finally a
public HTTP(S) guid/id. Candidates are not confirmation. The public resource
identity and revision do not change when the discovery result changes.

## Operations

Additional HTTP requests are **off by default**:

    Setting.external_bridge_rss_activitypub_discovery = true

The normal RSS bridge master switch and its tester allowlist must also permit
the source. The separate Sidekiq pull worker checks again at execution time.
Up to two public item URLs are probed per source invocation. A claimed item is
leased for 30 minutes, successful/unavailable entries for seven days, and
inaccessible/error entries for one day. Normal feed refresh or subscribe
schedules subsequent work; there is no unbounded traversal of a feed or
user-visible polling loop.

The fetch uses the existing public Request implementation, with redirect/DNS
private-address checks, a credential/query fail-closed URL validator, a
separate 10 requests/hour per-host budget, a 256 KiB response ceiling and
tight timeouts. ActivityStreams JSON is parsed locally, without retrieving
remote JSON-LD contexts. Only a whitelisted content-object type is accepted.
A valid AS2 context, HTTP(S) object id and expected Content-Type are required.
A candidate URL change invalidates all previous verification data. Error
classes, not remote bodies, are logged.

This is deliberately conservative. Some real AP URLs use query strings outside
the safe item allowlist, require signed GETs, or expose alternate representations
through discovery mechanisms not yet supported. Such cases remain unknown,
inaccessible, or unavailable rather than being silently counted as verified.
Site-wide NodeInfo verification, web page rel=alternate discovery, and API/UI
use of the detected metadata are later work.

Useful Rails console inspection:

    ExternalSource.find(id).slice('activitypub_hint', 'activitypub_state')
    ExternalResource.find(id).slice('activitypub_state', 'activitypub_candidate_url', 'activitypub_object_id', 'activitypub_object_type', 'activitypub_checked_at')

No migration backfill/probe is initiated automatically. A source with a normal
refresh eventually records candidates; probing only runs after opt-in.
