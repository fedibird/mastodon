# Cursor task: expand custom-filter URL matching to ordinary URLs

## Context

PR #123 ("Include quoted and referenced status URLs in custom filter matching") introduced `Status#filterable_text` and changed custom-filter matching / streaming transport to use it.

The current behavior after #123 is intentionally asymmetric:

- `Status#searchable_text` keeps body text but strips ordinary URLs.
- `Status#filterable_text` contains `searchable_text` plus public/ActivityPub URLs for resolved quoted/referenced statuses.
- Ordinary body URLs are still omitted from `filterable_text`.
- Elasticsearch and `KeywordSubscribe` still use `searchable_text`.

We now want ordinary body URLs to be filterable as well.

This task is a follow-up to #123. Keep the existing separation between searchable/indexable text and custom-filter text.

## Goal

Change `Status#filterable_text` so that **all URLs returned by `Status#urls` are eligible for custom-filter matching**.

For URLs that correspond to a resolved referenced status, expand the URL through:

- `ActivityPub::TagManager#url_for`
- `ActivityPub::TagManager#uri_for`

so that both the public URL and ActivityPub URI can match.

For an expansion result that is `nil`, use the **original URL being processed** as the fallback. For a URL that does not correspond to a resolved status reference, keep the original URL as-is.

Deduplicate the final URL list.

Conceptually, each source URL should behave like:

```text
source URL
  |
  +-- corresponds to an already-resolved referenced Status
  |      |
  |      +-- url_for(target) || source URL
  |      +-- uri_for(target) || source URL
  |
  +-- no resolved referenced Status
         |
         +-- source URL
```

Do **not** perform network resolution merely to make an ordinary URL filterable. Use the already available `references` association when deciding whether a URL maps to a referenced status.

## Required semantics

### 1. Ordinary body URL becomes filterable

Example body:

```text
hello https://example.com/article
```

Required:

- `status.searchable_text` still does **not** contain `example.com`
- `status.filterable_text` **does** contain `https://example.com/article`
- a Mastodon custom filter for `example.com` or the full URL matches
- streaming filtering receives the same filterable text and also matches

### 2. Referenced status still expands to public URL + ActivityPub URI

For a remote referenced status such as:

```text
public URL: https://example.social/@bob/123
AP URI:     https://example.social/users/bob/statuses/123
```

`filterable_text` must contain both forms, even if the body/reference source URL contains only one of them.

### 3. nil expansion falls back to source URL

If `url_for(target)` returns `nil`, retain the source URL for that slot.

If `uri_for(target)` returns `nil`, retain the source URL for that slot.

After `uniq`, this may result in one source URL plus whichever alternate form is available.

The important invariant is:

> A URL that appeared in `Status#urls` must not disappear from `filterable_text` merely because TagManager cannot produce one of its alternate representations.

### 4. No regression for Home/REST/reblog/streaming behavior from #123

Keep:

- `CustomFilter.apply_cached_filters` using `status.proper.filterable_text`
- `FanOutOnWriteService#attach_streaming_searchable_text` transporting `status.proper.filterable_text`
- reblogs using `proper`
- nested REST quote objects not exposing the internal transport field
- the existing `_fedibird_searchable_text` key
- the existing Node filtering logic that prefers that field

### 5. Preserve preloading behavior

#123 added a regression test ensuring a status whose `references` association is already loaded does not query `status_references` again while building `filterable_text`.

Keep that property.

Do not introduce per-URL DB queries.

## Suggested implementation shape

The current implementation has:

```ruby
def filterable_text
  @filterable_text ||= [
    searchable_text,
    filterable_reference_urls.join("\n"),
  ].filter(&:present?).join("\n\n")
end
```

and:

```ruby
def filterable_reference_urls
  references.flat_map do |reference|
    [
      ActivityPub::TagManager.instance.url_for(reference),
      ActivityPub::TagManager.instance.uri_for(reference),
    ]
  end.compact.uniq
end
```

Replace the reference-only helper with a URL-oriented helper (name is up to you, e.g. `filterable_urls`) whose input set is `Status#urls`.

Build an in-memory mapping from the already-loaded/resolved `references` to their known URL forms. A source URL that maps to a referenced Status should be expanded via `url_for` / `uri_for`; otherwise keep the source URL.

Do not call `uri_to_resource`, `ResolveURLService`, WebFinger, HTTP, Sidekiq, or any other resolver from `filterable_text`.

Keep the implementation simple enough that `filterable_text` remains safe on the hot paths used by REST filtering and streaming fan-out.

## Important existing behavior of Status#urls

At the current base, `Status#urls` is:

```ruby
def urls
  @urls ||= ProcessStatusReferenceService.urls(self, urls: references.map(&:url))
end
```

and `ProcessStatusReferenceService.urls` returns parsed/normalized status URLs plus the supplied resolved-reference URLs, excluding the status's own public URL / URI.

Use this existing URL set rather than reparsing HTML/text independently.

## Files likely involved

Expected production code:

- `app/models/status.rb`

Expected regression tests to update/add:

- `spec/models/status_filterable_text_spec.rb`
- `spec/models/custom_filter_spec.rb`
- `spec/models/status_searchable_text_spec.rb`
- `spec/services/fan_out_on_write_service_streaming_searchable_text_spec.rb`
- `streaming/filtering.test.js`

Do not modify unrelated indexing or subscription code just to make tests pass.

## Tests to change from #123

#123 intentionally asserted that ordinary body URLs were omitted. Those assertions now need to change.

In particular, find and update tests equivalent to:

- "does not include ordinary body URLs"
- "does not match an ordinary body URL"
- streaming payload "ordinary body URLs are omitted"
- `Status#searchable_text` spec that currently couples the searchable-text assertion to a CustomFilter non-match

The new contract is:

- searchable_text strips ordinary URL
- filterable_text includes ordinary URL
- CustomFilter matches ordinary URL
- streaming internal field includes ordinary URL

The searchable-text-only assertions themselves should remain.

## Required regression coverage

Please cover at least:

1. local status with an ordinary external URL:
   - absent from `searchable_text`
   - present in `filterable_text`

2. CustomFilter matches the ordinary URL.

3. streaming internal field contains the ordinary URL and matches it in Node filtering.

4. remote HTML status with an ordinary anchor URL behaves the same.

5. referenced remote status with distinct public URL and ActivityPub URI includes both.

6. `url_for(reference) == nil` falls back to the original source URL without losing `uri_for(reference)` if present.

7. `uri_for(reference) == nil` falls back to the original source URL without losing `url_for(reference)` if present.

8. duplicates collapse.

9. reblog uses the original status's complete `filterable_text`, including ordinary URLs.

10. preloaded references do not cause an extra `status_references` query.

## Non-goals

Do not change:

- `Status#searchable_text` URL stripping
- Elasticsearch / `StatusesIndex`
- `KeywordSubscribe` semantics
- StatusReference schema
- quote/reference creation semantics
- URL resolution/background workers
- REST serializer schema
- `_fedibird_searchable_text` field name
- generic Node filter matching algorithm

This PR is specifically about what goes into `filterable_text`.

## Validation

Run the focused Rails suite:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/models/custom_filter_spec.rb \
  spec/models/status_filterable_text_spec.rb \
  spec/models/status_searchable_text_spec.rb \
  spec/services/fan_out_on_write_service_streaming_searchable_text_spec.rb
```

Run Node filtering tests:

```bash
node --test streaming/filtering.test.js
```

Run RuboCop on every Ruby file modified by this PR.

If a pre-existing test encodes #123's old "ordinary URLs are not filterable" rule, update the test to reflect the new contract rather than preserving the old assertion.

## Acceptance criteria

The PR is ready when all of the following are true:

- ordinary URLs are present in `filterable_text`
- ordinary URLs are still absent from `searchable_text`
- referenced status URLs expand to public URL and ActivityPub URI
- a nil `url_for` or `uri_for` never causes the source URL to disappear
- no network resolution is added to filter evaluation
- no N+1/reference-preload regression
- REST and streaming custom-filter matching agree
- Elasticsearch and KeywordSubscribe behavior is unchanged
- focused RSpec, Node tests, and RuboCop are green
