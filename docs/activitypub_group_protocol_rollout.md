# Group Actor advertisement: staging verification (#748)

The published JSON-LD vocabulary is complete (#752). The Actor emitter from PR #751 has been merged, but is **OFF by default**. This guide covers a limited staging verification; it is not permission to enable the feature across production Groups.

## Preconditions

Use one **operator-controlled, non-suspended local Group**, one unrelated Group, and one Person as negative controls. Identify the local Group's `Account.id` (NOT `User.id`) on the staging Rails instance.

    GROUP_USERNAME=testgroup RAILS_ENV=production bundle exec rails runner '
      account = Account.find_by!(username: ENV.fetch("GROUP_USERNAME"), domain: nil)
      abort "not a local live Group" unless account.local? && account.group? && !account.suspended?
      puts "Account.id=#{account.id}; Actor=/users/#{account.username}"
      pp GroupProtocol::ProfileReader.new(account).call
    '

The profile must have server authority and the expected mention + completed Follow + public/unlisted + Announce(original URI) behavior. The self-declaration does not authorize anyone to post.

## Rollout matrix (staging web processes ONLY)

1. OFF with empty allowlist: no new Actor property and no new inline context term.
2. `FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT=true` with empty allowlist: still absent.
3. Flag true with a *different* Account ID: still absent for the target.
4. Flag true with **only the chosen local Group Account ID**: the target advertises the exact Group v1 profile URI; other Group and Person do not.
5. Remove the ID from allowlist: the claim disappears.
6. Set flag false: original Actor and context restored.

These environment values are read by web processes. Use the ordinary staging service configuration and restart/redeploy **all** web processes for every state; changing the invoking shell is not sufficient. Never edit production flags for this test.

## Read-only smoke test

The script only fetches an **unsigned** ActivityPub Actor GET; it never changes flags or restarts anything. It requires curl and jq, expects the canonical /users/:username HTTPS URL, and checks 200, `application/activity+json`, Actor type/id/publicKey, absence of viewer/role grants, and exact presence/absence of the new JSON-LD property and context. It writes headers and actor.json to OUTPUT_DIR.

    ACTOR_URL=https://staging.example/users/testgroup
    OUTPUT_DIR=/tmp/group-off bash script/group_actor_advertisement_smoke.sh "$ACTOR_URL" off

After choosing the target Account ID and enabling on staging:

    BASELINE_JSON=/tmp/group-off/actor.json OUTPUT_DIR=/tmp/group-on \
      bash script/group_actor_advertisement_smoke.sh "$ACTOR_URL" on

The optional baseline diff removes **only** the new property and its context entry before comparing all other Actor fields. If any other field differs, investigate profile edits or other changes rather than silently ignoring the diff. Repeat OFF verification after allowlist removal and after disabling the flag.

**Signed GET must be tested separately** with a real signature from another controlled ActivityPub server. If authorized-fetch mode rejects anonymous GET, the failure is expected; test via the valid signed requester instead of weakening authorized-fetch settings. Check Cache-Control, ETag, Vary and signed-vs-unsigned output equivalence where applicable. Repeat after cache TTL (Actor HTTP cache is approximately 3 minutes), accounting for proxy and remote caches.

## Independent JSON-LD validation

On a trusted workstation with rdflib installed in an isolated environment, extract **only the inline protocol context** from the ON Actor and use rdflib as an independent JSON-LD processor; do not dereference arbitrary remote contexts. In the resulting RDF graph, the property must be `https://fedibird.com/ns/group/v1#protocols` and its sole object must be `https://fedibird.com/ns/group/v1#MentionFollowAnnounce`. The following is a verification command for the saved ON actor:

    python3 - /tmp/group-on/actor.json <<'PY'
    import json, sys
    from rdflib import Graph, URIRef
    with open(sys.argv[1], encoding="utf-8") as f:
        actor = json.load(f)
    c = actor["@context"]
    c = c if isinstance(c, list) else [c]
    terms = [x["fedibirdGroupProtocols"] for x in c if isinstance(x, dict) and "fedibirdGroupProtocols" in x]
    assert len(terms) == 1
    fragment = {"@context": {"fedibirdGroupProtocols": terms[0]},
                "fedibirdGroupProtocols": actor["fedibirdGroupProtocols"]}
    g = Graph().parse(data=json.dumps(fragment), format="json-ld")
    p = URIRef("https://fedibird.com/ns/group/v1#protocols")
    v = URIRef("https://fedibird.com/ns/group/v1#MentionFollowAnnounce")
    assert list(g.objects(None, p)) == [v]
    print("PASS: independent JSON-LD protocol expansion")
    PY

This tests the **new protocol field**, not every external ActivityStreams/security context.

## Acceptance and rollback

Record the OFF → empty → wrong ID → target ID → remove ID → OFF matrix, anonymous and valid signed fetches, redacted Actor snapshots/headers, exact JSON-LD expansion, negative controls, NodeInfo/WebFinger/REST unchanged, and any extra outbound GET, SQL/allocations or delivery fan-out. Any unexpected disclosure, other Actor changes, invalid context, cache inconsistency or receiver incompatibility is a STOP condition.

Rollback is to remove the allowlisted ID and set `FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT=false` across web instances, then restart as required; account for proxy and remote TTLs. A rollback does not require DB changes. **Do not activate production Groups** until #748 review explicitly approves the results.
