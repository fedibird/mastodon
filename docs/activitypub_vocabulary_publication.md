# Fedibird JSON-LD vocabulary publication

Tracks #752. Related Actor emitter: #748 / PR #751. The files under `public/ns/` are the **canonical machine-readable vocabulary artifacts**; Markdown and HTML descriptions are explanatory only.

## Public resources

| Canonical document URL | Source of truth | Human-oriented document |
| --- | --- | --- |
| `https://fedibird.com/ns` | `public/ns/index.jsonld` | `https://fedibird.com/ns/index.html` |
| `https://fedibird.com/ns/group/v1` | `public/ns/group/v1.jsonld` | `https://fedibird.com/ns/group/v1.html` |

The existing legacy IRIs start with **`http://fedibird.com/ns#`** and MUST remain unchanged in `ContextHelper`. HTTP→HTTPS redirect for dereferencing the document does **not** turn those IRIs into HTTPS IRIs. New v1 Group terms use `https://fedibird.com/ns/group/v1#...`. Fragments are not included in HTTP requests. The published documents describe the stable terms without asserting unknown RDF domain/range/authorization semantics.

The Actor field in #748 uses its current **inline** JSON-LD context, not the vocabulary document as a remote context. Keeping this separation avoids network requests in serializer/consumer code.

## Deployment configuration

`dist/nginx.conf` contains the example mapping for the extensionless canonical URLs and explicit `.jsonld` paths. Nginx serves files from `public/` with `Content-Type: application/ld+json`, `Cache-Control: public, max-age=86400`, `X-Content-Type-Options: nosniff`, and `Access-Control-Allow-Origin: *`. HTML documents are served from their normal static file paths. The existing port-80 HTTP→HTTPS redirect remains in place. This implementation deliberately does not negotiate HTML/JSON-LD at the same URL; HTML has explicit URLs.

**Important:** Updating `dist/nginx.conf` does not change an operator's existing Nginx configuration. Apply its matching locations to the actual `fedibird.com` virtual host and run `nginx -t` before reloading. Confirm that a reverse proxy, CDN, custom `location` or old service worker is not intercepting the paths. Do not deploy it with the Actor emission flag enabled by default.

## Verification on staging / deployment host

```sh
nginx -t

curl -fsSI -H 'Accept: application/ld+json' https://fedibird.com/ns
curl -fsSI -H 'Accept: application/ld+json' https://fedibird.com/ns/group/v1
curl -fsSI https://fedibird.com/ns/index.jsonld
curl -fsSI https://fedibird.com/ns/group/v1.jsonld
curl -fsSI https://fedibird.com/ns/index.html
curl -fsSI https://fedibird.com/ns/group/v1.html
curl -sSI http://fedibird.com/ns
curl -fsS https://fedibird.com/ns/group/v1 | jq -e '."@graph" | length == 2'
```

Check: HTTPS canonical paths return **200, JSON-LD Content-Type, correct CORS and Cache-Control**; explicit file URLs return the same bytes; HTML is `text/html`; HTTP dereferencing redirects to HTTPS while document's legacy IRIs remain `http://...`. Use an independent JSON-LD 1.1 processor to expand both documents and verify every `@id`. These remote checks cannot be completed by repository CI alone.

Run `RAILS_ENV=test bundle exec rspec spec/lib/activitypub/ns_vocabulary_spec.rb` and `bundle exec rubocop spec/lib/activitypub/ns_vocabulary_spec.rb` after checkout.

## Stability / coordination

- Once a term is published, do not delete or repurpose it. Use a distinct IRI / `/v2` for breaking changes; preserve `/v1` indefinitely.
- When adding `ContextHelper` legacy `fedibird:` terms, define them in `public/ns/index.jsonld` in the same PR; the RSpec fixture contract checks both directions.
- PR #751 currently carries `docs/activitypub_group_protocol_v1.jsonld`. Once #752 merges, **delete that duplicate** on #751's branch and repoint `spec/lib/activitypub/group_protocol_jsonld_spec.rb` and documentation to `public/ns/group/v1.jsonld` before merging #751.
- PR #751's Group Actor emission flag stays default OFF until public HTTP tests, independent JSON-LD expansion, signed/unsigned Actor checks, cache/rollback and staging interoperability are verified. This PR does not alter posting authorization, federation routing, or remote capability trust.
