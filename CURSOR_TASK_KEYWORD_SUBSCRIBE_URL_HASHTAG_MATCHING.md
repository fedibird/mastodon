# Cursor task: extend Keyword Subscribe matching to URLs and hashtags

## Goal

Extend Fedibird Keyword Subscribe with two new matching options:

- `match_hashtags`
- `match_urls`

This PR is intentionally scoped.

We are NOT redesigning Keyword Subscribe as a whole. The work is limited to:

1. adding the two options to persistence/UI/API
2. deciding which status text/channels are presented to the matcher
3. rewriting the generated regular expression for non-regexp keyword subscriptions so URL/hashtag matching works correctly
4. adding a thorough characterization + regression test matrix

Use strong reasoning here. The existing regex is subtle and predates the current `Status#filterable_text` / `filterable_urls` support.

## Branch / base

Work on:

`feature/keyword-subscribe-url-hashtag-matching`

Base:

`1ac92fe46383a21b919dc2af6631ec105d3908a4`

(#153 merged)

---

# Current implementation: read this first

Relevant files:

- `app/models/keyword_subscribe.rb`
- `app/services/fan_out_on_write_service.rb`
- `app/models/status.rb`
- `app/controllers/settings/keyword_subscribes_controller.rb`
- `app/controllers/api/v1/keyword_subscribes_controller.rb`
- `app/views/settings/keyword_subscribes/_fields.html.haml`
- `app/views/settings/keyword_subscribes/_keyword_subscribe.html.haml`
- `app/serializers/rest/keyword_subscribes_serializer.rb`
- `app/models/tag.rb`
- `spec/models/status_filterable_text_spec.rb`
- existing FanOut specs

Current delivery is:

```ruby
s.match?(status.searchable_text)
```

for both home and list keyword subscriptions.

Current `Status#searchable_text`:

- includes CW/spoiler text
- includes plaintext body
- strips URLs discovered by `Status#urls`
- includes poll options
- includes media descriptions

Current `Status#filterable_text`, added for custom filter / streaming work:

- includes `searchable_text`
- adds `filterable_urls`

Current `Status#filterable_urls` already handles:

- ordinary URLs from the status
- reference source URLs
- canonical URL and ActivityPub URI expansion for StatusReference targets
- de-duplication

Reuse this. Do NOT create another URL parser.

Current non-regexp KeywordSubscribe regex generation is:

```ruby
Regexp.new(regexp ? words : "(?<![#])(#{words.split(',').map do |k|
  sb = case k when /\A[A-Za-z0-9]/ then '(?<![A-Za-z0-9])' when /\A[\/\.]/ then '' else '(?<![\/\.])' end
  eb = case k when /[A-Za-z0-9]\z/ then '(?![A-Za-z0-9])'  when /[\/\.]\z/ then '' else '(?![\/\.])'  end

  /(?m#{ignorecase ? 'i': ''}x:#{sb}#{Regexp.quote(k).gsub("\\ ", "[[:space:]]+")}#{eb})/
end.join('|')})", ignorecase, timeout: 2.0)
```

Do not casually edit this without first writing characterization tests.

Important observations:

- `(?<![#])` was intended to keep ordinary keywords from matching hashtag text.
- ASCII alphanumeric boundaries are handled separately.
- `/` and `.` have special boundary treatment.
- CJK/non-ASCII behavior differs intentionally from ASCII word behavior.
- the current hashtag guard is only immediate-preceding-`#`; it is not a complete semantic "not inside hashtag" detector.
- `regexp: true` bypasses all generated boundary logic and uses the user regex as-is.
- raw regexp subscriptions currently run against `status.searchable_text`, so visible hashtag text may already be matchable by an explicit regex.
- URLs are not currently available to regexp subscriptions because searchable_text removes them.

Preserve these facts explicitly in tests before changing behavior.

---

# Part A: persistence and API/UI options

Add nullable-safe boolean columns:

```text
keyword_subscribes.match_hashtags boolean default false null false
keyword_subscribes.match_urls     boolean default false null false
```

No backfill other than DB defaults.

Update schema annotations.

Update both parameter surfaces:

- Settings::KeywordSubscribesController
- Api::V1::KeywordSubscribesController

Update `REST::KeywordSubscribesSerializer` to expose both booleans.

Do not opportunistically repair unrelated serializer fields in this PR.

Update settings UI:

- edit/new form: two checkboxes
- index table: clearly show whether hashtag and URL matching are enabled

Suggested Japanese meaning:

- ハッシュタグも対象にする
- URLも対象にする

English:

- Match hashtags
- Match URLs

Add concise help text if useful.

Defaults must be off so existing ordinary keyword subscriptions do not suddenly gain URL/hidden-tag matches.

Do not change uniqueness semantics in this PR. Existing duplicate detection remains as-is even though it does not include every flag.

---

# Part B: matching contexts, not one accidental mega-string

Avoid solving this by blindly replacing:

```ruby
status.searchable_text
```

with:

```ruby
status.filterable_text
```

for every subscription.

That would make URLs available to every subscription and does not solve hashtag semantics.

Prefer explicit semantic matching contexts.

The useful conceptual channels are:

1. body/searchable text
2. URL values
3. hashtag values

## Body channel

The legacy body channel is `status.searchable_text`.

Default matching must remain based on this channel.

Do not modify global `Status#searchable_text` semantics for this feature.

## URL channel

When `match_urls` is enabled, use:

```ruby
status.filterable_urls
```

as the URL source.

Do not parse URLs again.

Do not use only the rendered URL text: reference canonical URL and ActivityPub URI support from #123 must work.

Treat each URL as a deliberate URL matching context. Avoid joining strings in a way that lets a regex/keyword span from the body into a synthetic URL or from one URL into another.

## Hashtag channel

When `match_hashtags` is enabled, expand the status's associated hashtags even if they are not visibly present in the body.

Use the status's tag association, not merely text scanning.

Use all relevant `status.tags`, not `tags_without_mute`; Keyword Subscribe matching should not depend on the status author's tag-mute relation.

Represent a tag as a hashtag token such as:

```text
#fediverse
```

using the canonical tag name unless there is a very strong repository-local reason to use another representation.

This must support remote/hidden tags that are associated with a Status but absent from `searchable_text`.

Avoid concatenating hashtag tokens in a way that permits a regex to span two tags.

## Re-use / helper location

It is acceptable to add a small Status helper or a small matcher helper so FanOut does not reconstruct the same channels per subscription.

Do not turn this into a broad Status text refactor.

Do not change:

- Elasticsearch status text
- `Status#searchable_text` meaning
- `Status#filterable_text` meaning
- streaming filter payload semantics
- custom filter semantics
- hashtag-follow semantics

---

# Part C: regular expression mode must stay raw

For `regexp: true`:

- do NOT rewrite the user's regexp source
- preserve ignorecase behavior
- preserve regexp validation
- preserve the regexp timeout behavior used for matching
- preserve default legacy matching against `status.searchable_text`

The new options may add extra semantic channels:

- `match_urls` -> also try raw regexp against URL channel(s)
- `match_hashtags` -> also try raw regexp against explicit hashtag token channel(s)

Important compatibility point:

A raw regexp may already match a visibly-written hashtag because visible hashtag text can be part of legacy `searchable_text`.

Do NOT silently remove/mask visible body text merely to make `match_hashtags: false` a hard exclusion for raw regexp mode unless you can prove that this does not break existing behavior.

Preferred compatibility interpretation for regexp mode:

- body matching remains exactly the legacy searchable_text behavior
- the two options add semantic URL / associated-tag channels
- the raw regexp itself remains authoritative

Document this in code/tests.

Do not invent regex rewriting for regexp mode.

---

# Part D: rewrite non-regexp keyword pattern generation deliberately

For `regexp: false`, the stored comma-separated keyword list is converted into regex.

Refactor this generation so the boundary behavior is explicit and testable for each matching context.

A small private PatternBuilder / helper is acceptable if it makes the semantics clear. Do not build a generalized matching framework beyond this use case.

Preserve:

- comma-separated alternatives
- normalization
- whitespace matching via `[[:space:]]+`
- `ignorecase`
- ASCII word-boundary behavior
- intentional CJK/non-ASCII substring behavior unless a test proves otherwise
- regex timeout

## Body context

When matching the body/searchable text, ordinary keyword behavior should continue to avoid treating a hashtag token as ordinary body keyword content.

The existing single `(?<![#])` is not sufficient to express "not somewhere inside a hashtag" for all Tag syntax.

Use repository hashtag semantics:

- `Tag::HASHTAG_NAME_PAT`
- `Tag::HASHTAG_RE`
- `Tag::HASHTAG_SEPARATORS`

where useful.

Do not invent an ASCII-only hashtag parser.

The implementation may solve this through:
- a better context-aware generated pattern,
- safe masking/extraction of known hashtag spans before ordinary-keyword matching,
- or another small, well-tested approach.

But do not make a user regex go through this rewriting.

Important: default `match_hashtags: false` should not accidentally match a normal keyword merely because it appears inside an associated/visible hashtag. Include tests for positions beyond immediately after `#`.

## Hashtag context

When `match_hashtags: true`, ordinary keyword subscriptions must be able to match explicit hashtag tokens.

Examples to support according to existing keyword boundary philosophy:

- keyword `foo` matches `#foo`
- case behavior follows `ignorecase`
- hidden associated `#foo` matches even if body does not contain it
- keyword `foo` should not become a generic substring of ASCII `#foobar` if normal ASCII end-boundary rules would reject `foobar` in body text
- CJK matching should remain consistent with existing CJK keyword behavior
- keyword containing `#` itself should be characterized and given a deliberate result, not left to an accidental lookbehind

Do not force whole-tag equality if that would contradict existing Keyword Subscribe keyword semantics. Preserve normal keyword-boundary philosophy while allowing hashtag context.

## URL context

When `match_urls: true`, ordinary keyword subscriptions must be able to match URL material intentionally.

Examples:

- keyword `example` matches `https://example.com/path`
- keyword `example.com` matches the domain
- keyword `pathword` matches `https://example.com/pathword`
- a full URL keyword can match the full URL
- reference canonical URL and ActivityPub URI are matchable
- ignorecase behavior remains whatever the subscription requests

Do not let old slash/dot guards accidentally make the new URL option ineffective.

At the same time, retain ordinary ASCII partial-word protection where meaningful:

- keyword `ample` should not start matching inside ASCII token `example` simply because it is in a URL, unless existing keyword semantics already allow that context intentionally

The key distinction is:

- URL punctuation such as `.`, `/`, `:`, `?`, `&`, `=`, `#` must not act as the old "do not match URL" mechanism when URL matching is enabled
- ASCII alphanumeric token boundaries should remain deliberate

## Independent options / ambiguous punctuation

Treat URL and hashtag contexts independently.

Important test case:

```text
https://example.test/#foo
```

- with URL matching enabled, URL content is available as URL context
- hashtag option refers to Status hashtag entities/tokens, not URL-fragment syntax
- with hashtag matching enabled but URL matching disabled, a `#foo` URL fragment should not become a hashtag match unless the Status also has an associated hashtag `foo`

Do not rely on one global `(?<![#])` to distinguish these contexts.

---

# Part E: include and exclude keyword semantics

`exclude_keyword` must use the same context selection as `keyword`.

For a subscription:

- body is always legacy base context
- URL channel is available iff `match_urls`
- hashtag channel is available iff `match_hashtags`

A positive match should be excluded if `exclude_keyword` matches any enabled relevant context.

Do not create different URL/hashtag options for include vs exclude in this PR.

Test examples:

- include body keyword, exclude URL keyword with match_urls=true
- include hashtag keyword, exclude another hashtag keyword with match_hashtags=true
- disabled context must not make exclude_keyword suppress a status

---

# Part F: FanOut integration

Update both:

- `deliver_to_keyword_subscribers_home`
- `deliver_to_keyword_subscribers_list`

Do not regress:

- visibility scoping
- ignore_block behavior
- media_only
- list/home routing
- without_local_followed_* behavior
- no keyword-subscribe delivery for reblogs

Avoid expensive text reconstruction for every subscription.

There are only four flag combinations:

```text
hashtags=false urls=false
hashtags=true  urls=false
hashtags=false urls=true
hashtags=true  urls=true
```

It is acceptable to memoize/build status matching channels once and reuse them.

Do not prematurely optimize with a large architecture rewrite, but avoid calling Formatter / URL expansion / tag loading hundreds of times for the same status.

---

# Part G: characterization tests BEFORE behavior changes

The current `spec/models/keyword_subscribe_spec.rb` is empty. Fill it with serious characterization coverage.

Before rewriting the matcher, establish the current intended behavior for ordinary body keywords.

At minimum characterize:

## Existing keyword normalization

- surrounding whitespace stripped
- repeated whitespace collapsed
- comma-separated keywords normalized
- blank entries removed
- duplicates removed
- spaces inside one keyword become `[[:space:]]+`

## Existing ASCII boundaries

For keyword `foo`:

- matches `foo`
- matches punctuation-delimited `(foo)`
- does not match `foobar`
- does not match `barfoo`
- characterize `foo-bar`
- characterize `foo_bar`

For keyword beginning/ending punctuation:
- leading `.`
- trailing `.`
- leading `/`
- trailing `/`

Do not change these accidentally.

## Existing non-ASCII/CJK

Use Japanese examples.

Characterize substring behavior such as:
- keyword `東京`
- surrounding Japanese characters
- punctuation
- whitespace

Preserve this unless there is an explicit reason not to.

## Existing hashtag behavior

Characterize what the current generated pattern does for:

- `#foo`
- `#foobar`
- `#foo_bar`
- keyword `bar` inside `#foo_bar`
- Japanese `#東京`
- keyword `京` inside a longer Japanese hashtag
- keyword explicitly containing `#`

Some of these may reveal bugs in the old guard. Record the old behavior first, then make the NEW intended behavior explicit in separate tests.

## Existing regexp behavior

For `regexp: true`:

- source is used raw
- case sensitivity follows ignorecase
- visible hashtag text in searchable_text is characterized
- invalid regex validation unchanged
- exclude regexp behavior unchanged

---

# Part H: new test matrix

Add focused model/matcher tests plus FanOut integration tests.

The following matrix is the minimum, not the maximum.

## 1. Default: match_hashtags=false, match_urls=false

Ordinary keyword:
- matches ordinary body text
- does not match ordinary URL-only occurrence
- does not match referenced URL/URI-only occurrence
- does not match hidden hashtag-only occurrence
- does not accidentally match inside visible hashtag token, including underscore/CJK cases targeted by the old weak guard
- ignorecase true/false still works

Regexp:
- legacy searchable_text behavior remains
- URL-only material is unavailable
- hidden hashtag-only material is unavailable
- raw source is unchanged

## 2. match_urls=true only

Ordinary keyword:
- domain component
- path component
- full URL
- ordinary local body URL
- remote HTML anchor URL if covered by Status/filterable URL behavior
- referenced status canonical URL
- referenced status ActivityPub URI
- no hidden hashtag-only match

Regexp:
- raw regexp can match added URL channel
- raw regexp source is not rewritten

## 3. match_hashtags=true only

Ordinary keyword:
- visible hashtag
- hidden associated hashtag
- ASCII boundary behavior inside tag
- underscore separator case
- Japanese/CJK tag case
- no URL-only match

Regexp:
- raw regexp can match explicit associated hashtag token
- hidden associated tag now works
- regexp source remains raw

## 4. both true

- status can match by body, URL, or hashtag
- URL fragment `#foo` is URL context, not mistaken for a Status hashtag entity
- hidden hashtag remains independently matchable
- no cross-channel synthetic regex match

## 5. exclude_keyword

For body / URL / hashtag:
- exclusion works when corresponding channel enabled
- URL exclusion does not apply when match_urls=false
- hashtag exclusion does not apply to hidden-tag channel when match_hashtags=false
- positive and exclude patterns use same case option / regexp mode

## 6. multiple comma keywords

- one alternative can match body
- another can match URL
- another can match hashtag
- no malformed grouping / precedence regression

## 7. timeout / invalid regex regression

- matcher retains regex timeout
- invalid raw regexp continues validation error
- generated keyword strings remain safely escaped

Include metacharacter keywords such as:

```text
c++
a.b
foo/bar
(foo)
[bar]
?```

as appropriate, proving `Regexp.quote` behavior remains safe.

---

# Part I: FanOut service integration coverage

Add a dedicated spec if clean, suggested:

`spec/services/fan_out_on_write_service_keyword_subscribe_spec.rb`

Prove actual delivery IDs, not only matcher return values.

At minimum:

- home subscriber matched by body
- home subscriber matched only by URL when match_urls=true
- same URL subscription not delivered when match_urls=false
- list subscriber matched only by hidden hashtag when match_hashtags=true
- same hashtag subscription not delivered when false
- exclude_keyword prevents delivery in URL context
- exclude_keyword prevents delivery in hashtag context
- visibility scope behavior remains
- reblog still does not keyword-deliver

Do not over-mock the matching input; use real Status associations where practical.

---

# Part J: database / migration

Add one migration for both columns.

Suggested shape:

```ruby
add_column :keyword_subscribes, :match_hashtags, :boolean, default: false, null: false
add_column :keyword_subscribes, :match_urls, :boolean, default: false, null: false
```

No other schema changes.

---

# Part K: scope exclusions

Explicitly DO NOT do these in this PR:

- no broad KeywordSubscribe redesign
- no rename of `ignorecase` / `regexp`
- no change to subscription count limits
- no change to duplicate/uniqueness semantics
- no change to account/domain/tag subscribe systems
- no change to hashtag-follow behavior
- no Elasticsearch changes
- no custom-filter behavior change
- no streaming filtering behavior change
- no `Status#searchable_text` semantic change
- no `Status#filterable_text` semantic change
- no unrelated serializer cleanup
- no front-end React rewrite
- no performance architecture beyond small caching/memoization needed for these options

If you identify a larger design flaw, record it in the PR body under "Follow-up", but do not expand this PR.

---

# Compatibility decisions

Use the following priorities when existing behavior and clean semantics conflict:

1. Preserve raw regexp source exactly.
2. Preserve default body matching behavior.
3. Preserve existing ASCII/CJK keyword boundary behavior unless it directly prevents the new option from working.
4. Make URL/hashtag matching additive and context-aware.
5. Fix clearly unintended hashtag leakage in generated non-regexp keyword matching with explicit regression tests.
6. Do not silently change raw-regexp visible-body behavior to enforce a stricter hashtag-off rule.

If you find an unavoidable ambiguity not covered here, choose the smallest backwards-compatible behavior and describe it explicitly in the PR body.

---

# Validation

Run focused RSpec for:

- KeywordSubscribe model/matcher
- Status filterable URL/text specs
- new FanOut keyword-subscribe integration spec
- existing FanOut specs
- settings keyword subscribe controller
- API keyword subscribe controller/serializer specs if present or add focused coverage
- migration/schema-sensitive tests as appropriate

Run RuboCop on every changed Ruby/spec file.

If a full relevant spec group exposes an unrelated baseline failure, separate it clearly from feature failures.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Add URL and hashtag matching options to Keyword Subscribe`

PR body must state:

- the two new flags and their defaults
- URL matching reuses `Status#filterable_urls`
- hidden hashtags come from Status tag associations
- raw regexp source remains unchanged
- non-regexp keyword pattern generation was rewritten/contextualized
- exact compatibility behavior for regexp + visible hashtags
- exact ASCII/CJK boundary behavior retained
- how URL punctuation differs from ordinary body boundary handling
- how hidden hashtags are represented
- exclude_keyword uses the same enabled contexts
- no custom filter / streaming / Elasticsearch semantic change
- exact migration
- exact RSpec result
- exact RuboCop result
- any discovered old hashtag-boundary bug and how the new tests define it
- any follow-up design issue intentionally left out of scope

## Final cleanup

Delete this handoff file before final PR diff.

## Completion report

Return:

- Draft PR number / URL
- head/base SHA
- exact changed files
- migration name
- new DB/API/UI fields
- matching-context implementation
- normal-keyword regex generation before/after summary
- raw-regexp compatibility behavior
- exact hashtag semantics
- exact URL semantics
- exclude_keyword semantics
- characterization matrix results
- FanOut integration coverage
- exact RSpec result
- exact RuboCop result
- any ambiguity/deviation/follow-up
