# ActivityPub Actor JSON: Nginx cache bypass and verification (#814)

## Why

During #748 testing, an allowlisted Group returned the old OFF Actor response on the canonical URL with `X-Cached: HIT`; a unique query produced `MISS` and the correct ON advertisement; after 180 seconds the original URL returned `EXPIRED` and the correct JSON. Thus Rails' ON/OFF cache-key isolation alone cannot prevent **Nginx** from serving an old Actor body.

## Scope of the Nginx change

`dist/nginx.conf` adds three `map` values in the **http context** and both `proxy_cache_bypass` and `proxy_no_cache` to `location @proxy`. The condition is true **only** for an Actor path (`/users/:username`, `/@username` or `/actor`) **and** an `Accept` header containing `application/activity+json` or `application/ld+json`.

- BYPASS prevents reading existing cached Actor data, even when previously HIT.
- NO_CACHE prevents writing new Actor data to the proxy cache.
- HTML profiles, other routes and media retain the existing Nginx policy.
- Rails `render_with_cache` continues its 3-minute caching using the existing default/advertisement-specific keys.
- The Actor's `Cache-Control: max-age=180` is **not changed** here; external clients and remote proxies can still retain a response. This is an Nginx local-cache fix, **not** an instantaneous global revocation mechanism.

The application/ActivityPub serializer and authentication logic are unchanged. Do not use a per-request `?cache_bust=...` as the permanent solution; that only fixes an isolated test and does not protect canonical Actor URLs.

## Isolated test

With a local Nginx 1.26.3 and a test HTTP upstream using `Cache-Control: public, max-age=180` and `Vary: Accept`, we verified:

| Operation | X-Cached |
| --- | --- |
| Actor ActivityPub GET before applying bypass (first, repeat) | MISS, HIT |
| Same canonical cached Actor URL after config reload | BYPASS, BYPASS |
| `Accept: application/ld+json; profile=...` on Actor URL | BYPASS |
| `/@actor` ActivityPub GET | BYPASS |
| HTML `/users/actor` (first, repeat) | MISS, HIT |
| `/api/v1/instance` ordinary GET (first, repeat) | MISS, HIT |

An isolated negative test stopped the upstream after seeding an Actor cache entry: the patched proxy returned **502**, not the stale Actor response. These are **isolated fixture responses**, not dev/prod HTTP results.

## Dev deployment and acceptance

1. Confirm the actual `dev.fedibird.com` vhost Nginx configuration and `proxy_cache_key`/locations. Apply the new `map` directives in the `http` context and the bypass/no-cache directives to the actual `@proxy` (or equivalent) configuration; merely merging `dist/nginx.conf` does not update existing vhosts.
2. Test `sudo nginx -t`, then `sudo systemctl reload nginx` for the dev host only. Leave `FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT` as currently approved for the single dev Group; do not enable it globally or on production.
3. Fetch the canonical Actor twice with the normal `Accept` header and **no query parameters**:

   ```sh
   ACTOR_URL=https://dev.fedibird.com/users/seven_days_war
   for i in 1 2; do
     curl -fsS -D "/tmp/ap-cache-${i}.headers" \
       -o "/tmp/ap-cache-${i}.json" \
       -H 'Accept: application/activity+json' "$ACTOR_URL"
     grep -Ei '^(x-cached|cache-control|vary):' "/tmp/ap-cache-${i}.headers"
     jq -r '.fedibirdGroupProtocols // [] | join(",")' "/tmp/ap-cache-${i}.json"
   done
   ```

   Expect both responses to show `X-Cached: BYPASS` (or prove the request reaches Rails by independent access log), never `HIT`/`STALE`/`UPDATING`. When dev is in test-only authorized-fetch mode use a signed requester instead of expecting anonymous 200.

4. Re-run the Group OFF→ON→OFF smoke test for the canonical URL **without waiting 180 seconds**. The new Actor claim must be added/removed immediately after all web workers have the new environment values; inspect both `X-Cached` and field/context. Do not change the live `fedibird.com` Group flag.
5. Check ordinary HTML and API GET requests still use the original cache policy where eligible; inspect Nginx access logs before/after for cache hit ratio, Rails request rate and 5xx. In authorized-fetch mode unsigned requests should still receive 401, valid signed GET should return the correct Actor with private/no-store policy as appropriate. If upstream is unhealthy, prefer failure to stale advertised Group claims.
6. Continue the remaining #748 requirements: negative Groups/Persons, independent JSON-LD, signed GET (already tested), A/B allowlist fail-closed, receiver interoperability. Keep production enablement separate.

## Serializer cost measurements (dev only)

From the dev Rails working tree, run the read-only benchmark:

```sh
cd /home/mastodon/live
GROUP_USERNAME=seven_days_war ITERATIONS=40 RAILS_ENV=production \
  bundle exec rails runner script/benchmark_group_actor_advertisement.rb
```

This benchmarks **direct Actor serialization**, not HTTP or proxy throughput. It toggles `ENV` only inside the runner process, compares four consecutive OFF/ON rounds, and restores the process environment. It does not alter the running web service, permissions, membership, DB or advertised server state. Report p50/p95 serialization time, allocations/call, SQL queries/round. Network/HTTP/Rails cache effects require separate short, bounded dev-only request measurements; do not issue uncontrolled load against public servers.

## Failure or rollback

If Nginx BYPASS fails, confirm whether the real vhost inherits `@proxy` or uses a different cache location/key. Inspect `nginx -T` securely (redact private internal configuration), `X-Cached`, `Vary`, application response and cache status. Never flush the entire shared cache directory as a shortcut. To reverse the Nginx change, remove the two bypass directives and maps from **dev only**, `nginx -t`, reload and verify existing behavior. Keep the production Group advertisement flag OFF. For removal of already-federated claims, remote caches have independent TTLs and an Actor re-fetch may still be necessary.

## References

- #748 staging measurements, #751 Actor emitter, #760 read-only smoke test, #814.
- Nginx official: https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_bypass and https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_no_cache
