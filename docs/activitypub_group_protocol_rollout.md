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

## Recorded dev/nightly acceptance (2026-11-15 JST)

These are **actual operator-reported test results**, separate from the reusable procedure above. The dev host was `dev.fedibird.com`; the sole allowlisted local Group was `seven_days_war` (Account.id `117541749236683382`). No production Group was enabled.

- Baseline flag OFF: canonical `/users/seven_days_war` passed `expected off` (200, ActivityPub JSON, no property/context or viewer privilege fields).
- Target-only ON: canonical Actor passed `expected on` including the exact versioned IRI/context and unchanged normalized baseline. Different Group `pirates_of_the_caribbean` and Person `admin` returned no advertisement. The target ON value was independently reconfirmed. The response logs alone do not prove that the target/negative requests used an identical web-process configuration; rely on the operator's setting-change record for that stronger claim.
- Remove Account.id from allowlist (while emit true): OFF smoke passed. Full flag OFF: OFF smoke passed. Wrong-ID-only allowlist: OFF smoke passed with Nginx `BYPASS`; the actual wrong Account.id and web service environment were not captured in the submitted output, so exact configuration provenance remains operator-attested. Empty allowlist and the remove-ID stage represent the same end-state.
- Independent Python `rdflib` fragment expansion of saved ON JSON: `https://fedibird.com/ns/group/v1#protocols` mapped to `https://fedibird.com/ns/group/v1#MentionFollowAnnounce` (PASS). This is not a full expansion of all externally hosted JSON-LD contexts.
- `nightly.fedibird.com` sent a signed GET using `https://nightly.fedibird.com/actor#main-key`: 200 and exact expected Actor/field/context. With authorized fetch temporarily required on dev, an unsigned GET returned 401 while signed GET returned 200 with `Cache-Control: private`. The authorization change must be reverted after testing.
- Nightly `FetchResourceService` parsed and accepted the remote Group actor and profile IRI. Nightly `ActivityPub::FetchRemoteAccountService` created a remote Group Account (Account.id `117619978336047812`) with expected URI, type, public key, and inbox. **That test writes nightly DB state**; it is not read-only, and associated background jobs are not proven complete.
- Nginx initially returned an old OFF Actor with `X-Cached: HIT` after ON was enabled. Separate [#814](https://github.com/fedibird/mastodon/issues/814) / merged [PR #815](https://github.com/fedibird/mastodon/pull/815) added Actor JSON cache read+write bypass (including Rails JSON MIME aliases, `?format=json`, and `.json` suffixes). Dev canonical Actor responses showed `X-Cached: BYPASS`; immediate ON→OFF and final OFF each passed the baseline diff with `BYPASS`. HTML profile remained 200/MISS (max-age=0) and the unrelated instance API remained 200/HIT. **The repo Nginx example does not configure live production vhosts automatically**.
- Direct Actor serializer performance, 40 calls per mode and two OFF/ON pairs: p50/p95 approximately 1.4–2.3 ms in both modes; 40 SQL queries per 40 calls in either mode (no extra SQL), and ~59 additional Ruby allocations/call on ON (~2.9%). This does not measure Nginx bypass traffic. A one-hour production access-log sample found 19,295 Actor-path GET/HEAD candidates (11.43% of 168,847), peak 769/minute, no candidate-path 5xx; those include HTML and pre-existing cache MISSes, **not** the actual extra Rails request volume.
- Final rollback verification: `/tmp/group-final-off/actor.json` and headers passed `expected off; HTTP 200; application/activity+json`, with `X-Cached: BYPASS`.

**Remaining boundaries:** Verify live dev `AUTHORIZED_FETCH` has been restored to its intended value; only the operator can verify the actual web environment. This runbook does not establish compatibility with every independent ActivityPub implementation, complete NodeInfo/WebFinger/REST legacy diffs, or background-job fan-out under production traffic. Do not infer production readiness from the smoke script alone. The staged advertisement remains operator-gated and disabled by default.
