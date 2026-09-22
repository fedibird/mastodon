# Cursor task: add human-readable URL variants to filterable matching

## Context

#154 is merged.

Merge commit:

`c7380cb5a0bacdd56682e1cbf405f78f191a07fa`

It added URL/hashtag options to Keyword Subscribe and intentionally left one follow-up:

- `Status#filterable_urls` contains canonical/normalized URL forms
- non-ASCII path/query text is therefore percent-encoded
- a user who writes a filter/keyword such as `東京` does not match a visible URL like `https://example.com/東京/page`
- this is unintuitive for both Custom Filter and Keyword Subscribe

Example current behavior:

```text
visible URL:
https://example.com/東京/page

Status#filterable_urls:
https://example.com/%E6%9D%B1%E4%BA%AC/page

keyword/filter:
東京

current result:
no URL match
```

The fix should make matching agree with the human-visible link representation while preserving canonical encoded URL matching.

## Branch / base

Work on:

`feature/filterable-url-readable-variants`

Base:

`c7380cb5a0bacdd56682e1cbf405f78f191a07fa`

---

# Product contract

For every canonical URL that participates in `Status#filterable_urls`:

1. keep the canonical/encoded URL exactly as today
2. safely derive a human-readable/display URL variant
3. if the display variant differs and is safe, add it as an additional filterable URL
4. if decoding fails or produces unsafe/invalid text, keep only the canonical form

Do NOT replace canonical URLs with decoded URLs.

The resulting semantics should be:

```text
canonical:
https://example.com/%E6%9D%B1%E4%BA%AC/page

additional matching representation:
https://example.com/東京/page
```

Both forms should match.

This applies to all consumers of `filterable_urls`, including:

- Custom Filter / REST-side filter matching through `filterable_text`
- Node streaming filter transport through `_fedibird_searchable_text`
- Keyword Subscribe with `match_urls=true`

No consumer should implement its own decoding.

---

# Part A: extract the existing Formatter display decoding

There is already related code in `app/lib/formatter.rb`:

```ruby
def link_html(url)
  decoded_url = Addressable::URI.unencode(Addressable::URI.parse(url).to_s)
  url         = decoded_url if decoded_url.valid_encoding?
  ...
end
```

Refactor this into one small reusable Formatter method.

Suggested public API:

```ruby
Formatter.instance.display_url(url)
```

or another equally clear name.

The method should return a String and never raise for malformed URL input.

Then make `link_html` use that helper so:

- the link's visible text keeps the same human-readable behavior
- Status filterable matching uses exactly the same display representation
- href / canonical URL behavior remains unchanged

Do not make `Status` duplicate this logic.

`Status` already depends on `Formatter.instance.plaintext`, so using the same Formatter utility does not introduce a new architectural layer dependency.

---

# Part B: safe decode contract

The display helper must be defensive.

Conceptually:

```text
input canonical URL
  ↓
parse
  ↓
percent-decode exactly once
  ↓
is valid UTF-8?
  ↓
contains no control characters?
  ├─ yes -> return decoded variant
  └─ no  -> return original canonical input

parse/decode error
  -> return original canonical input
```

## Exact requirements

### Decode once only

Do NOT recursively decode.

Example:

```text
%252F
-> %2F
NOT /
```

### Valid UTF-8 only

A percent sequence that produces invalid UTF-8 must fall back to the original encoded URL.

Examples to test include malformed/invalid byte sequences such as `%FF` or an incomplete UTF-8 sequence.

Do not rely only on `String#valid_encoding?` if the decoded String remains tagged with a binary encoding. Ensure the accepted result is actually valid UTF-8.

### Reject decoded control characters

Do not add a decoded variant if percent decoding introduces Unicode control characters.

At minimum this must reject:

- NUL `%00`
- `%01`
- `%02`
- CR/LF
- DEL / C1 controls where applicable

Prefer a Unicode control-character check (e.g. category `Cc`) rather than listing only three bytes, if it is clean in Ruby.

This is especially important because #154 uses:

- NUL as the Keyword Subscribe synthetic segment separator
- U+0001 as hashtag marker
- U+0002 as URL marker

A decoded URL must never be able to inject those control characters into matching material.

If a decoded variant is rejected, the canonical percent-encoded URL remains available and matching continues to work with it.

### Reserved punctuation

Do not reject a decoded variant merely because percent decoding produces URL punctuation such as:

- `/`
- `?`
- `#`
- `%`

Formatter already presents decoded URL text to humans.

Because this decoded value is only an alternate matching/display representation and NOT URL identity, decoding reserved punctuation is acceptable.

Canonical encoded URL remains alongside it.

### Rescue only the relevant parsing/encoding failures

Determine the exact exceptions Addressable raises for the tested malformed inputs and rescue the appropriate ones.

Avoid an unnecessary blanket `rescue StandardError`.

The public helper should nevertheless satisfy the contract: malformed input returns its original String and does not raise.

---

# Part C: preserve href / identity

This PR must NOT change:

- href generated by Formatter
- `Status#urls`
- ActivityPub URI identity
- reference matching/indexing
- redirect handling
- URL normalization
- link-card behavior
- canonical forms returned by TagManager
- Elasticsearch semantics

Example:

For an encoded input URL:

```text
href:
https://example.com/%E6%9D%B1%E4%BA%AC

visible link text:
...東京...

filterable_urls:
https://example.com/%E6%9D%B1%E4%BA%AC
https://example.com/東京
```

The display/helper result must never be substituted into href.

---

# Part D: add display variants AFTER canonical URL expansion

Current `Status#filterable_urls` first resolves/expands source URLs and StatusReference forms.

Preserve that logic.

Do not feed decoded/display variants back into:

- `filterable_reference_index`
- `expand_filterable_source_url`
- `expanded_urls_for_reference`

Instead:

1. produce the same canonical URL array #123/#154 produce today
2. de-duplicate canonical forms
3. for each canonical URL, append its safe display variant
4. final `compact.uniq`

Suggested shape:

```ruby
canonical_urls.flat_map do |url|
  [url, Formatter.instance.display_url(url)]
end.compact.uniq
```

The exact helper naming is flexible.

Keep deterministic order:

- canonical form first
- decoded/display variant immediately after it when distinct

For an ASCII URL whose display form is identical, return one entry only.

---

# Part E: filterable_text behavior

`Status#filterable_text` should naturally inherit the new variants through `filterable_urls`.

Do not add another decoded-URL expansion in `filterable_text`.

Test that both encoded and decoded forms occur.

Do not change `Status#searchable_text`.

#154's KeywordSubscribe MatchingText will continue masking a URL written in body text and then adding `filterable_urls` only when `match_urls=true`.

That is the desired behavior.

---

# Part F: Keyword Subscribe behavior

Do not redesign #154.

Add focused regression/integration coverage proving:

## match_urls=true

For:

```text
https://example.com/東京/page
```

ordinary keyword:

```text
東京
```

matches.

Raw regexp:

```text
東京
```

also matches.

Encoded keyword/regexp such as:

```text
%E6%9D%B1%E4%BA%AC
```

continues to match because canonical encoded form is preserved.

## match_urls=false

The same CJK keyword/regexp does NOT match URL-only material.

This must keep #154's URL-off guarantee.

## URL fragment

For a canonical URL containing encoded fragment material, the decoded URL variant remains a URL region.

It must not become a Status hashtag entity.

`match_urls=true, match_hashtags=false` may match decoded `#foo` URL text because it is URL material.

Do not change hashtag semantics.

## Control-character fallback

A URL with an encoded control byte must not create a decoded synthetic URL segment containing #154's separator/marker characters.

Canonical encoded form remains matchable.

---

# Part G: Custom Filter coverage

This follow-up exists partly because the problem affects filters, not only Keyword Subscribe.

Locate the actual current Custom Filter matching path that consumes `Status#filterable_text`.

Add focused coverage proving that a filter keyword / regex for a human-readable CJK string can match a percent-encoded URL through the new decoded variant.

At minimum cover:

- CJK path
- encoded canonical form still matches
- ordinary non-URL body semantics unchanged

Do not change filter matching algorithms themselves if `filterable_text` is sufficient.

If existing filter specs are difficult to exercise end-to-end, a `Status#filterable_text` model spec plus the nearest existing filter integration spec is acceptable, but explicitly report what was exercised.

---

# Part H: streaming transport coverage

#123 made streaming custom-filter matching use:

```ruby
status.proper.filterable_text
```

through:

`FanOutOnWriteService#attach_streaming_searchable_text`

Add/extend the existing streaming searchable-text spec so the transport field contains the human-readable decoded URL variant.

Do not modify Node filtering code.

Do not modify the transport field name.

Do not add decoded URL fields to REST status serialization.

---

# Part I: Formatter tests

Add direct tests for the extracted display helper and link output.

Minimum matrix:

1. plain ASCII URL -> unchanged
2. CJK percent-encoded path -> decoded display URL
3. CJK percent-encoded query value -> decoded display URL
4. percent-encoded emoji -> decoded display URL
5. decode only once: `%252F -> %2F`
6. invalid URI -> original input, no raise
7. invalid UTF-8 percent bytes -> original input
8. NUL/control-producing encoding -> original input
9. normal reserved encoded punctuation can decode in display form
10. `link_html` / actual formatted link still uses canonical encoded href while visible text follows display helper

Preserve existing link formatting behavior for valid URLs.

---

# Part J: Status#filterable_urls tests

Extend `spec/models/status_filterable_text_spec.rb`.

Minimum cases:

### ordinary body URL

```text
https://example.com/%E6%9D%B1%E4%BA%AC/page
```

Expect:

```ruby
filterable_urls == [
  'https://example.com/%E6%9D%B1%E4%BA%AC/page',
  'https://example.com/東京/page',
]
```

or equivalent deterministic ordering.

### ASCII URL

No duplicate variant.

### StatusReference canonical URL / URI

If either form contains percent-encoded non-ASCII text, both canonical and display variants should be available.

Do not let decoded variants alter which reference the URL maps to.

### malformed/control URL

Only canonical form returned.

### filterable_text

Includes both canonical encoded and display decoded representations.

---

# Part K: naming / documentation

The helper is a display/matching representation, not a URL decoder for identity.

Choose naming/comments that make that distinction obvious.

Good concepts:

- display URL
- human-readable URL
- filterable display variant

Avoid names implying the decoded string is canonical or safe to use as href.

Add a short comment where `filterable_urls` expands display variants:

> Keep canonical URL forms and add the same human-readable representation Formatter uses for link text.

---

# Part L: no migration / scope exclusions

No DB migration.

Do NOT change:

- KeywordSubscribe schema/options
- KeywordSubscribe regex PatternBuilder
- #154 region markers/separators
- custom filter data model
- Node streaming filtering implementation
- StatusReference semantics
- Elasticsearch
- href identity
- ActivityPub identifiers
- URL fetching
- redirect resolution

This is a representation-layer follow-up only.

---

# Compatibility expectations

The change is additive for URL matching.

Before:

```text
%E6%9D%B1%E4%BA%AC -> match
東京             -> no URL match
```

After:

```text
%E6%9D%B1%E4%BA%AC -> match
東京             -> match
```

Existing encoded regex/filter strings must continue to work.

ASCII URLs should produce no duplicate behavior.

---

# Validation

Run focused specs for:

- Formatter URL/link behavior
- Status filterable text/URLs
- KeywordSubscribe CJK URL matching
- FanOut streaming searchable-text transport
- nearest Custom Filter integration/model matching specs

Also run #154's key matching specs as regression:

- KeywordSubscribe matching text
- KeywordSubscribe matching matrix
- FanOut Keyword Subscribe delivery

Run RuboCop on every changed Ruby/spec file.

If broad Formatter specs have known baseline failures, compare against current `fedibird` and report baseline separately.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add human-readable URL variants to filterable matching`

PR body must state:

- canonical URL forms remain unchanged and first-class
- display variants are additive
- Formatter link text and filter matching share one safe decoding helper
- decode is one-pass only
- invalid UTF-8 / malformed input falls back
- decoded control characters are rejected
- href / ActivityPub identity are unchanged
- Custom Filter now matches CJK URL text users see
- Keyword Subscribe `match_urls=true` now matches CJK decoded URL text
- encoded URL filters remain compatible
- streaming searchable text inherits the same representation
- no schema migration
- exact RSpec/RuboCop results
- any baseline failures

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR number / URL
- head/base SHA
- exact changed files
- helper name and safety contract
- exact rescued exception classes
- exact control-character rule
- filterable_urls ordering/dedup behavior
- Formatter href/display behavior
- Custom Filter proof
- Keyword Subscribe proof
- streaming transport proof
- exact RSpec result
- exact RuboCop result
- any deviation or unresolved edge case
