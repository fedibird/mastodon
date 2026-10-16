# Fedibird filter match batch API (P1)

`POST /api/v1/fedibird/filters/matches` evaluates the authenticated user's current filters against already-known status IDs. This is read-only. It does not return posts, matching text, filter titles/actions/contexts, or another account's filters. Clients obtain definitions from the existing `GET /api/v2/filters`. This change adds no React/Redux integration.

## Request and response

Send `Content-Type: application/json` and a bearer access token:

```json
{"status_ids":["123","456","789","123"]}
```

```json
{"matches":{"123":["12","18"],"456":[]},"unavailable":["789"]}
```

IDs and object keys are decimal **strings**, never JSON numbers. `status_ids` is required and must be an array of 0–100 entries **before** deduplication. Each entry must match `[1-9][0-9]*` and fit a positive signed PostgreSQL bigint (`9223372036854775807` maximum). Whitespace, signs, leading zeroes, fractional/exponential forms, booleans, nulls, nested values and numeric JSON values are rejected. Validation precedes database lookup; mixed valid/invalid input fails in full. Rails' null-array normalization is deliberately bypassed for this validation. Duplicates are removed, preserving first occurrence order in each response partition. Filter ID order is unspecified; use a set.

`matches` contains every requested, available status ID, including an explicit empty array when evaluation completed without matches. `unavailable` contains requested IDs that do not exist, are inaccessible, are discarded/expired, are unreleased Page objects, or have an unavailable reblog original. These reasons are intentionally indistinguishable. Never interpret `unavailable` as a confirmed empty match. An empty request returns `{"matches":{},"unavailable":[]}`.

Request bodies are limited to **8192 bytes**, including whitespace and ignored fields. A middleware bounds reads before Rails parameter parsing/logging, also for requests without Content-Length. Matching paths with escaped characters, repeated separators, format suffixes and trailing slashes receive the same bound. `status_ids` is redacted in Rails parameter logs. Response bodies are limited to **1 MiB**; an oversized result fails in full, so clients can retry smaller batches. Matches are never silently truncated.

## Authentication, authorization, and errors

Both status-read **and** filter-read capabilities are required. Doorkeeper 5.8.2's `includes_scope?` checks multiple arguments with `any?` (OR); two separate authorization callbacks therefore require `(read OR read:statuses) AND (read OR read:filters)`. An umbrella `read` token is accepted, as on existing APIs. A token with only either narrow scope is rejected. Existing confirmed/approved/functional-user checks remain in force. There is no target account parameter: only `current_account` supplies filters.

Responses use `Cache-Control: private, no-store` on successful requests (including empty requests); normal API errors retain the existing no-store headers. Body-limit errors also have private/no-store headers.

| Status | Meaning |
| --- | --- |
| 200 | Complete result, possibly with unavailable IDs |
| 400 | Malformed JSON |
| 401 | Missing, expired or revoked token |
| 403 | Insufficient scope or disabled/unapproved user |
| 413 | Body larger than 8192 bytes |
| 415 | Content-Type is not application/json |
| 422 | Invalid/missing status_ids, over 100 entries, oversized match result; existing API user checks also apply |
| 429 | Existing Rack::Attack API rate limit exceeded |

The existing authenticated API quota (1200 requests per five minutes) applies. Large bodies are rejected before controller authentication, without looking up any status or filter. Error responses reveal no status availability.

## Matching and visibility semantics

The service uses the same `StatusFilter` and `StatusPolicy` checks as permitted-status retrieval, with batch-loaded account relationships. It explicitly applies `StatusPolicy#show?` even to owned posts, whose StatusFilter fast path otherwise bypasses policy. Both wrapper and original must pass access checks, including blocks, mutes, domain blocks, suspension and special visibility. Default kept/non-expired status scopes intentionally classify expired/discarded records as unavailable, including those an individual include-expired endpoint might expose.

`CustomFilter.cached_filters_for(current_account.id)` is called once for a nonempty batch. Its existing expiry checks and keyword/status cache invalidation remain authoritative. `CustomFilter.apply_cached_filters` performs all matching. Its optional `filterable_status:` argument permits the batch to use its eagerly loaded original instead of `Status#proper`'s additional query. Existing callers retain their previous default behavior. Accounts, mentions, media, polls, references/reference accounts and reblog originals are eager loaded; full Status/Media/Emoji/Reaction serializers and the full relationship presenter are not constructed for this API.

A reblog is evaluated using its original's `filterable_text`, but individual-post rules intersect **both wrapper and original IDs**, as in the existing evaluator. Each requested ID is evaluated independently. For example, a wrapper-only rule matches that wrapper and does not contaminate a separately requested original. The existing timeline relationship presenter copies a wrapper result onto its nested original's map entry; this API returns the wrapper's result under the requested wrapper ID, avoiding shared-map overwrite/order effects between multiple independently requested IDs. Serializer comparison tests cover both the direct serializer path and the presenter path for individual original/wrapper resources.

Body/CW/ALT/poll options, canonical/display URL variants and reference URLs keep their existing meaning. Referenced/quoted post bodies are not newly traversed. Unexpired filters of every action/context are returned, including on the viewer's own posts, consistently with REST `filtered`. Clients retain responsibility for context, hide/warn and their existing own-post exclusions. Filter definitions remain authoritative for expiration/action/context.

## Validation and measurement

The request/service/middleware specs cover input boundaries, narrow/umbrella scopes, token rejection, privacy, visibility, wrapper/original interactions, text sources, direct/presenter serializer equivalence, real cache invalidation, expiry and body/response limits. Existing policy, status text, StatusFilter and REST status/filter tests are also run for regressions.

`spec/requests/api/v1/filter_matches_performance_spec.rb` creates 50 remote originals with distinct authors, media ALT, polls and reference links, plus 50 wrappers with distinct local authors. It measures complete HTTP requests at 1 and 100 IDs after framework warmup, clearing Rails caches before each sample and disabling the ActiveRecord query cache. Fixture creation, schema and transaction-control queries are excluded. A fixed SQL budget guards against per-post relationship/text queries. The measured SQL count, response size and duration are printed by the test and reported in the PR.

These are local test measurements, not production throughput guarantees. Cost still depends on filter count/regular expressions, post text and reference volume; existing matching semantics are retained. There is no atomic snapshot across concurrently edited filters/posts, and an expired session or subsequent visibility change requires the usual client handling. Browser/Redux behavior and server deployment are outside P1.
