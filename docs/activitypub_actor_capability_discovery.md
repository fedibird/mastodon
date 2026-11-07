# ActivityPub Actor capability discovery — P3-A design contract

Status: **proposal for review; no on-wire additions in P3-A**.
Tracking: [#725](https://github.com/fedibird/mastodon/issues/725),
[#728](https://github.com/fedibird/mastodon/issues/728),
[GroupProtocol #662](https://github.com/fedibird/mastodon/issues/662).
The existing [capability discovery catalog](capability_discovery.md) remains
software-wide, while this design addresses Actor-specific federation.

## Why separate software and Actor discovery?

`/nodeinfo/2.0.metadata.fedibird.activitypub.supported` lists Fedibird
software implementation hints. It is not proof of what **this Actor**
implements, what **this Note** means, what an **Activity** will deliver,
or what **this viewer** may do. The existing `GroupProtocol` class
already distinguishes server authority, self-declared software identity,
protocol evidence, and viewer permissions.

| Layer | Existing source | Meaning | NOT implied |
| --- | --- | --- | --- |
| Software | NodeInfo / `Fedibird::CapabilityCatalog.nodeinfo` | Implementation-wide serializer features | Per-Actor support, authorization, current availability |
| Actor | `ActivityPub::ActorSerializer` | `type` (`Group` / `Person` / `Service` / `Application`), inbox/outbox, profile fields | Group posting protocol, role, permission |
| Note / Question | `ActivityPub::NoteSerializer` | Optional `audience`, `references`, legacy `quoteUri`, `searchableBy` | FEP-1b12, FEP-400e, consent-respecting quote authorization |
| Activity | `ActivityPub::EmojiReactionSerializer` and delivery policies | `EmojiReact` or `Like` as chosen per delivery | Every remote Actor accepts EmojiReact or a Like fallback |
| Group local profile | `GroupProtocol.public_metadata` | Local server-authoritative `fedibird_mention_follow_announce` | Permission for a particular viewer to post |
| Group remote profile | `GroupProtocol.assess` from saved evidence | Unknown/withheld or self-declared compatibility candidate | Remote Fedibird Group posting is automatically available |
| Viewer | `PostingContext` / Group permissions | Authenticated, subject- and actor-specific conditions | Safe to publish in an Actor/NodeInfo document |

`ActivityPub::NoteSerializer` publishes `references` for local Notes
and the legacy quote properties when relevant. These are **object
properties**, not Actor-wide FEP claims. In particular, an `audience`
that points to a Group does not by itself prove the Group's replication
mechanism. `EmojiReact` vs `Like` is an activity and receiver-dependent
delivery decision; it must not become a blanket Actor guarantee.

## Current Group protocol, verified in code

For a **local Fedibird Group** the authoritative existing profile is:

- Membership prerequisite: a completed Follow, not a pending request.
- Posting: mention the Group, with `public` or `unlisted` visibility.
- Distribution: the Group sends an ordinary `Announce` for the
  **original status URI**, not `Announce(Create)`.
- Owner/moderator role assignments are independent of Follow.
- `GroupProtocol.public_metadata(account)` contains no viewer,
  follows, role grants, or `can_post` authorization; its
  `authorizes_posting` field is always `false`.

For a **remote Group**, NodeInfo `software_name = fedibird` can only
yield a fresh, bound *self-declared implementation candidate*.
`GroupProtocol` must continue to return `profile.kind = unknown`,
`fedibird_posting = withheld`, and `authorizes_posting = false`.
The remote Fedibird software name, `type: Group`, and a user's Follow
are not permission to choose a posting transport. Keep
`PostingContext::DiscoveryService` and the local/remote allow rules
unchanged in this P3 design.

**Do not advertise FEP conformance for the local Group:**

| Mechanism | Local Fedibird code | Claim policy |
| --- | --- | --- |
| Fedibird mention+Follow+original URI Announce | Built-in server contract | Candidate for local Group-only Fedibird-specific IRI |
| FEP-1b12 Group federation | Distinct Announce/activity model | Do not claim complete FEP support |
| FEP-400e publicly-appendable collections | No reviewed collection target / Add lifecycle | Do not claim |
| FEP-5219 affiliations/permissions | Evidence may be present for remote groups; local roles are separate | Never upgrade to admin/owner or a posting grant from affiliation alone |
| Newer quote FEPs | Existing `quoteUri` is the legacy format | Do not claim without complete request/authorization tests |

The FEP-5219 draft has evolved during 2026. A future FEP claim needs a
**specific reviewed revision** and interop tests; do not hardcode a
role or `Grant`/relationship mapping based on an old draft.

## Wire format proposal (NOT implemented)

**Decision required before P3-B:** choose one stable term and IRI,
publish the vocabulary semantics at that URL, and test actual JSON-LD
compaction/expansion. A Group-only, vendor-scoped, additive extension is
preferred over pretending to implement an unrelated FEP. Candidate
shape for review only:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fedibirdGroupProtocols": {
        "@id": "https://fedibird.com/ns#groupProtocols",
        "@type": "@id",
        "@container": "@set"
      }
    }
  ],
  "type": "Group",
  "id": "https://server.example/users/group",
  "fedibirdGroupProtocols": [
    "https://fedibird.com/ns#MentionFollowAnnounce"
  ]
}
```

`https://fedibird.com/ns#groupProtocols` and
`https://fedibird.com/ns#MentionFollowAnnounce` are **provisional
identifiers**, not published/approved interoperability guarantees.
They MUST NOT appear on the wire until a separate review accepts
their stable meaning, resolution/documentation, and JSON-LD context.

Semantics of the candidate: a **self-description by this local Group**
of its concrete mention/Follow/original-URI-Announce profile. It is not
proof that anyone can post, not a claim that all Group actors on this
server use the profile, not FEP-1b12 or FEP-400e, and not a server-wide
advertisement. Do not serialize `canPost`, ownership, role assignments,
membership lists, Group viewer evidence, or any OAuth/session values.

### Export decision table for P3-B (draft)

| Actor | Candidate exported field | Basis |
| --- | --- | --- |
| Local live Group with confirmed profile | Local Group profile IRI only, if feature flag enabled | Server-authoritative profile, not viewer grant |
| Local Person/Service/Application | No Group profile field | Actor type isn't Group |
| Suspended Group | No new capability claim | Avoid stale claims or resurrecting access |
| Remote Group stored locally | Never re-serialize or inject local claims | Only its home server owns the published Actor |
| Unknown Group profile | Omit, not `false` | Unsupported by evidence, not proof of denial |
| Any Actor with only NodeInfo self-declaration | Omit | Software identity isn't actor-specific evidence |

The serialized Actor's ID, host and signing identity must continue
to be authoritative from the **local** Account. A remote Actor
document must never inherit Fedibird's local capability flags.

## Future receiver/consumer policy (not in P3-A)

1. Explicit IRI is *self-declared protocol evidence* only. Validate
   JSON-LD term expansion, exact allowlisted protocol IRI, same Actor
   identity/host binding, and freshness before storing. An unknown IRI
   or malformed document remains unknown; never `can_post = true`.
2. Do not issue additional Actor/NodeInfo GETs merely to discover the
   field; process the document already fetched in the normal safe
   ActivityPub pipeline. Do not follow arbitrary protocol IRI URLs
   in incoming data (SSRF, redirect, IP/host mismatch risks).
3. Preserve the `GroupProtocol` evidence model: `source`,
   `authority`, `freshness`, `uncertainty`, and `observed_at`.
   Expired or actor-mismatched evidence must not become authority.
4. Never use this value alone to allow group posting. `PostingContext`
   and final write-time checks remain authoritative. Follow acceptance
   is not equivalent to a Group owner/moderator role; external
   FEP-5219 affiliations are not local assignments.
5. A remote Group may advertise several independent protocols.
   Do not assume advertising one means support for another, even
   when a software family is known. No automatic remote adapter
   activation in this P3 phase.

## Test and rollout gates

### P3-A — this PR

- Add regression tests for the **existing** Actor and Note AP output:
  local Group `type: Group`, Person stays Person, Group `audience`
  and Note `references` retain meaning, no new protocol or
  viewer-specific capability fields.
- Test `GroupProtocol.public_metadata` includes only
  `PUBLIC_KEYS` and cannot grant posting on local or remote Groups.
- No serializer modifications, JSON-LD extensions, new routes, DB
  migrations, remote fetches, feature flag toggles, or delivery changes.
- Review the proposed IRI and shape before any subsequent PR writes
  on-wire capability metadata.

### P3-B — after design approval

- Provide a versioned, published definition for every emitted vendor
  IRI and a stable, correctly expanded JSON-LD context. Validate
  with both `ActivityPub::Adapter` and independent JSON-LD tooling.
- Add a **default-OFF**, operator-controlled emission flag. The flag
  only affects local Actor serialization and must not enable a new
  composer path, delivery strategy, API write, or remote classification.
- Unit/contract tests: Person vs local Group vs suspended Group;
  no viewer data, no mutation of legacy fields, unknown IRI
  tolerance, no false FEP claims, JSON-LD expansion/compaction, and
  negative evidence.
- Staging tests: unsigned/signed Actor GET, JSON-LD validation,
  `Content-Type`, ETag/cache/vary, caching/invalidation after
  profile or flag change; verify no accidental disclosure in
  WebFinger, NodeInfo or v1/v2 instance.
- Federation interop against at least one tolerant older receiver
  and one independently implemented AP parser. Sample/measure
  serialization throughput, allocations, SQL query count and
  Sidekiq fan-out, with and without the flag. No new external GET.
- Roll out to an admin/test group first, then small cohort. Roll back
  by disabling the Actor serialization flag; do **not** silently
  retract stored remote observations or change write authorization.

### P3-C — separately reviewed receiver path

- Only after P3-B, implement evidence storage/validation,
  allowlisted IRI parsing, actor identity binding, expiration, and
  downgrade. Keep remote Group posting **withheld** until a separate
  PostingContext design and authorization review.
- If FEP IRIs are later supported, require serializer, incoming
  parsing, outgoing delivery, moderation and independent end-to-end
  tests for **each** FEP. Do not equate Note `audience`,
  `quoteUri`, or Actor `type: Group` with full FEP support.

## References

- Fedibird [group protocol profile](group_protocol_profile.md),
  [capability discovery](capability_discovery.md), and Issue #662.
- [W3C ActivityPub](https://www.w3.org/TR/activitypub/) and
  [Activity Streams vocabulary](https://www.w3.org/TR/activitystreams-vocabulary/).
- [FEP-1b12: Group federation](https://fediverse.codeberg.page/fep/fep/1b12/)
  (final 2023-02-09).
- [FEP-400e: Publicly-appendable collections](https://fediverse.codeberg.page/fep/fep/400e/)
  (final 2022-02-04).
- [FEP-5219: Groups and permissions](https://codeberg.org/fediverse/fep)
  (draft in 2026; pin reviewed revision before interoperability claims).
