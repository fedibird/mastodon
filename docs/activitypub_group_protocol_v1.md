# Fedibird Group protocol advertisement v1 — P3-B

Status: **implemented behind a default-OFF, actor-ID-allowlisted gate**;
**do not enable in production before publishing the vocabulary and
passing staging/interoperability checks**. Tracking: [#748](https://github.com/fedibird/mastodon/issues/748),
[P3-A #747](https://github.com/fedibird/mastodon/pull/747),
[GroupProtocol #662](group_protocol_profile.md).

## Identity and exact protocol

The property and value IRIs in version 1 are:

| Use | Stable IRI |
| --- | --- |
| JSON-LD property | `https://fedibird.com/ns/group/v1#protocols` |
| First protocol profile | `https://fedibird.com/ns/group/v1#MentionFollowAnnounce` |
| Compact JSON key | `fedibirdGroupProtocols` |

These new **HTTPS** IRIs are distinct from the existing legacy
`http://fedibird.com/ns#` context, which remains unchanged. They are
constant, not negotiated by node software version, Account settings or
viewer permissions. Adding other profiles in the future requires
independent protocol review; it must not silently broaden this v1
profile's meaning.

**Semantics of `MentionFollowAnnounce`:**

- The Actor is a locally controlled Fedibird `Group` with the
  server-authoritative `fedibird_mention_follow_announce` profile.
- Submission requires mentioning the Group and a **completed Follow**
  membership (pending follows do not satisfy it). The supported
  visibilities are `public` and `unlisted`.
- The Group republishes the *original status URI* in a normal
  `Announce`, **not** `Announce(Create)`. There is no claim of
  FEP-1b12 Group federation or FEP-400e publicly appendable
  collections. FEP-5219 affiliations do not become local role or
  posting privileges.
- This profile is a **self-declared behavior contract**, not permission
  for any viewer to post or evidence that a remote Group offers the
  same protocol. Receiving servers must never promote a remote Group
  to `can_post` based on this field alone.

The companion `docs/activitypub_group_protocol_v1.jsonld` contains
the machine-readable property and protocol vocabulary. **At present,
the repository document alone does not prove that the public URL
`https://fedibird.com/ns/group/v1` serves that vocabulary.** The
operator must publish and verify that URL before enabling the flag;
its availability was not established during P3-B authoring.

## JSON-LD representation

For an eligible local Group with the gate enabled:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1",
    {
      "fedibirdGroupProtocols": {
        "@id": "https://fedibird.com/ns/group/v1#protocols",
        "@type": "@id",
        "@container": "@set"
      }
    }
  ],
  "type": "Group",
  "fedibirdGroupProtocols": [
    "https://fedibird.com/ns/group/v1#MentionFollowAnnounce"
  ]
}
```

The fragment above omits normal Actor attributes and other existing
context extensions; it is not a complete Actor response. A named
`@container: @set` preserves the array shape even for one protocol.
The term is inserted into the serialized `@context` **only when the
matching property is actually present**. With the gate off, both field
and context entry are absent and the Actor retains its existing
serializer output. No remote `@context` is loaded by the emitter.

## Fail-closed rollout configuration

P3-B requires two explicit environment variables:

```sh
FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT=true
FEDIBIRD_AP_GROUP_PROTOCOL_ACTOR_IDS=12345,67890
```

The emission switch accepts **only the exact string `true`**.
The allowlist contains numeric local Group `Account.id` values,
separated by commas or whitespace. An empty list, invalid entries, or
only setting the global switch enables **no Actors**. There is no
wildcard or auto-enrollment; administrators must intentionally add
individual Group IDs. The flags should remain unset/false in all
production and non-reviewed staging instances.

Emission also requires a non-suspended, non-instance, locally owned
Group Actor and the exact server profile. Persons, Service/Application
Actors, suspended Actors, remote Groups, unknown profiles and Groups not
in the allowlist never emit this field. The existing
`GroupProtocol::ProfileReader` is reused **without viewer state,
network requests, NodeInfo lookups or follower/role SQL queries**.

## Cache behavior and rollback

`AccountsController` uses `render_with_cache` for ActivityPub Actor
JSON with a default TTL of **3 minutes**. Its original cache key is
retained when the feature is off or the actor is not eligible. When an
advertisement is emitted, a versioned separate key is used so turning
the flag off or removing an Actor ID cannot reuse the advertised body.
The HTTP response still uses the original existing 3-minute
`Cache-Control` policy, signature-related `Vary` policy, and
authorization checks. Existing edge caches and remote servers may
retain an earlier Actor response until its TTL expires; rollback does
not retroactively delete already fetched metadata.

Rollback: set `FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT=false` and restart
the relevant web processes (and CDN/cache layers if in use). No
database migration, recipient actor trust state or delivery worker
configuration must be reverted.

## Pre-activation verification checklist

1. Publish `docs/activitypub_group_protocol_v1.jsonld` at
   `https://fedibird.com/ns/group/v1` with suitable stable content
   negotiation (JSON-LD where applicable) and documentation of the
   `#protocols` and `#MentionFollowAnnounce` IRIs. Confirm HTTPS and
   redirects. A URL path without a fragment is what an HTTP client
   retrieves; fragment identifiers are not sent in the HTTP request.
2. Validate both JSON-LD **expansion and compaction** using
   `spec/lib/activitypub/group_protocol_jsonld_spec.rb`, an
   independent JSON-LD processor, and the real Actor document from
   `ActivityPub::Adapter`.
3. On staging, exercise flag OFF, flag ON with no Group IDs,
   selected Group IDs ON, removing an ID, and flag OFF again.
   Verify public Actor GET, signed/authorized fetch, content-type,
   `Cache-Control`, `Vary`, legacy WebFinger and NodeInfo, and that
   no viewer, role, `canPost`, membership or credentials appear.
4. Confirm no new SQL queries or outbound GETs for Actor serialization;
   measure allocations and requests for large Group accounts.
   Test older clients that ignore unknown JSON-LD properties. Do
   not claim FEP-1b12/FEP-400e/FEP-5219 conformance.
5. Start with a single operator-controlled Group Actor after review,
   then increase the allowlisted IDs. Do not enable this without a
   published vocabulary. The site administrator decides deployment
   timing and the specific Group IDs.

No `PostingContext`, `GroupProtocol` receiver path, remote-Group
classification, posting API, group authorization or ActivityPub delivery
code changes are part of P3-B. Receiving and trusting an explicitly
advertised remote Group protocol will be designed separately.
