# Cursor follow-up: revise #154 matching semantics

## Context

PR #154 already exists:

- title: Add URL and hashtag matching options to Keyword Subscribe
- branch: `feature/keyword-subscribe-url-hashtag-matching`

A small prerequisite fix was split out and already merged as #155:

- merge commit: `179136091239078f856dd4d8d1dd40cfb7ade76a`
- removes stale `exclude_home` from `REST::KeywordSubscribesSerializer`
- adds a real serializer regression spec

Before changing #154, update/rebase/merge the branch onto current `fedibird` so #155 is included.

Then remove the temporary API/serializer workaround in #154. The #154 serializer spec must serialize a real KeywordSubscribe without stubbing `exclude_home`.

## Revised product decision

The matching semantics have changed from the original handoff.

### Old #154 implementation

The current branch has three matching channels:

- body
- urls
- hashtag_tokens

and raw regexp mode always sees the unmasked body, while ordinary keywords see a hashtag-masked body.

That is NO LONGER the desired contract.

### New contract

**Regexp and non-regexp subscriptions must receive the same preprocessed matching text.**

The two flags control preparation of the text before `KeywordSubscribe#match?` evaluates either:

- the generated keyword regexp, or
- the user-supplied raw regexp.

In other words, do not give raw regexp mode privileged access to material that a non-regexp subscription with the same flags does not receive.

---

# Part A: one prepared matching string per flag combination

Build one prepared string for a Status for each of the four combinations:

```text
match_hashtags=false, match_urls=false
match_hashtags=true,  match_urls=false
match_hashtags=false, match_urls=true
match_hashtags=true,  match_urls=true
```

The same prepared string is used for both include `keyword` and `exclude_keyword`, and for both `regexp: false` and `regexp: true`.

It is fine to keep a small `MatchingContexts` / `MatchingText` helper, but its output to the matcher should be one String, not separate body/url/tag match calls.

## Base body

Start from legacy:

`status.searchable_text`

This already excludes URLs discovered by Status.

Do not globally change `Status#searchable_text`.

## Hashtags disabled

When `match_hashtags == false`:

- remove/mask visible hashtag spans from the body before matching
- do not append associated hidden tags

Use repository hashtag semantics (`Tag::HASHTAG_RE` / related constants), not an ASCII-only parser.

Use a non-whitespace sentinel such as NUL when masking so a generated multi-word keyword cannot accidentally bridge across a removed hashtag.

Example:

`foo #hidden bar`

must not make keyword `foo bar` match merely because the hashtag was removed.

Important:

- this masking applies to raw regexp mode too
- a newly-created regexp subscription with match_hashtags=false must not see visible hashtag material
- this intentionally differs from the legacy raw-regexp behavior for newly-created rows

## Hashtags enabled

When `match_hashtags == true`:

- leave visible hashtag material in the body
- additionally expose every associated `status.tags` entry, including hidden/remote tags absent from body
- use explicit token form `#name`

Separate synthetic tokens using a non-whitespace sentinel so a normal generated keyword containing spaces cannot span separate tags.

Do not use `tags_without_mute`.

## URLs disabled

When `match_urls == false`:

- the string supplied to match must contain no URL matching material
- do not append `status.filterable_urls`

The base `status.searchable_text` is already URL-stripped; keep using it rather than inventing another URL parser.

## URLs enabled

When `match_urls == true`:

- append/reintroduce `status.filterable_urls` to the prepared string
- reuse exactly that URL source; no second parser
- include ordinary URLs, reference canonical URLs, and ActivityPub URI forms already provided by #123

Separate URL values with a non-whitespace sentinel.

A URL fragment `#foo` remains URL material. It must still be available when:

- match_urls=true
- match_hashtags=false

Hashtag masking applies to the BODY portion, not to the appended URL strings.

## Synthetic seams

Use a separator that generated whitespace keywords cannot bridge across.

Because the product decision explicitly uses one String, a deliberately broad user regexp may theoretically cross a synthetic separator if it explicitly matches that separator/all bytes. Do not build a large architecture solely to prevent that. Document the separator and pin the intended ordinary-keyword behavior.

---

# Part B: regexp mode uses the same prepared string

Remove the current special rule:

> raw regexp mode keeps legacy body behavior exactly and options only add channels

New rule:

`subscription.match?(prepared_text)`

uses the same prepared text regardless of `regexp`.

For `regexp: true`:

- regexp SOURCE remains exactly as user entered
- do not rewrite raw regexp syntax
- ignorecase behavior stays
- validation stays
- timeout stays
- only the INPUT STRING changes based on match_hashtags / match_urls

Examples:

### regexp, both false

Body:
`hello #fediverse https://example.test/foo`

The regexp must not receive hashtag material or URL material.

### regexp, hashtags true, URLs false

Can match:
- visible #fediverse
- associated hidden #fediverse

Cannot match:
- URL-only material

### regexp, hashtags false, URLs true

Can match:
- URL/domain/path/fragment material

Cannot match:
- visible body hashtag material unless the same bytes occur independently in URL material

### regexp, both true

Receives body + hashtag tokens + URL material.

---

# Part C: migrate EXISTING regexp subscriptions

This is an explicit compatibility/data decision.

Existing rows with:

`regexp = true`

must be migrated to:

```text
match_hashtags = true
match_urls     = true
```

Reason:

Existing regexp subscriptions were created under a model where users supplied an unrestricted regexp rather than generated keyword boundaries. Under the new common-preprocessing semantics, do not silently turn old regexp subscriptions into "body only, no hashtag/no URL" rows.

We intentionally opt existing raw-regexp rows into both new target classes.

This also means existing regexp subscriptions gain URL matching after migration. That expansion is intentional.

## Modify the existing not-yet-merged migration

#154 currently adds both columns in:

`db/migrate/20260922060000_add_match_hashtags_and_match_urls_to_keyword_subscribes.rb`

Because #154 is not merged yet, update this same migration.

Prefer explicit `up/down` if needed:

```ruby
def up
  add_column ... match_hashtags ... default false null false
  add_column ... match_urls ... default false null false

  execute <<~SQL.squish
    UPDATE keyword_subscribes
    SET match_hashtags = TRUE,
        match_urls = TRUE
    WHERE regexp = TRUE
  SQL
end

def down
  remove_column ...
  remove_column ...
end
```

Use repository migration conventions.

Do NOT migrate non-regexp rows; they remain false/false.

New regexp subscriptions also use normal defaults false/false unless the user selects the options.

Add migration/data-transition coverage if the repo test style permits it; at minimum make the SQL/data semantics explicit in the PR body and verify against a pre-existing regexp row in a migration-capable test.

---

# Part D: generated non-regexp pattern still needs option-aware rewrite

Even with the prepared text, the existing generated keyword regex itself contains guards that suppress hashtag/URL matches.

Therefore retain/refine the PatternBuilder work, but it no longer needs three separately-invoked matching channels.

Build the generated pattern from subscription flags.

Required semantics:

## Default false/false

Preserve legacy body keyword boundaries as far as possible:

- ASCII token boundaries
- existing CJK behavior
- punctuation behavior

Visible hashtag material has already been masked, so hashtag exclusion does not need to rely only on the old weak immediate `(?<![#])` guard.

## match_hashtags=true

The generated pattern must allow a keyword to match hashtag material in the prepared string.

Examples:

- foo matches #foo
- foo does not become a generic ASCII substring of #foobar
- foo / bar behavior in #foo_bar should stay consistent with the chosen existing keyword boundary semantics
- CJK stays consistent with existing CJK substring behavior
- explicit keyword containing # is deliberate and covered by tests

## match_urls=true

The generated pattern must allow URL punctuation that the legacy guards rejected.

Examples:

- example -> https://example.com/path
- example.com -> domain
- pathword -> URL path
- full URL -> full URL
- c++ -> .../c++/page where appropriate

Still preserve ASCII partial-token protection:

- ample must not match inside example
- athword must not match inside pathword

Since the matcher now receives one prepared string, enabling URL matching may require option-dependent punctuation rules that also exist for the rest of that prepared string. Characterize any body-side behavior change caused by this and choose the smallest compatible implementation.

Do not reintroduce separate per-context match calls merely to preserve the first #154 implementation.

---

# Part E: include/exclude use identical preprocessing

Both positive and negative matching use the exact same prepared string.

Pseudo-contract:

```ruby
text = prepared_text_for(status, match_hashtags:, match_urls:)

include_match = keyword_regexp.match?(text)
exclude_match = exclude_keyword.present? && exclude_keyword_regexp.match?(text)

include_match && !exclude_match
```

The actual implementation may cache patterns/text, but the semantics should look like this.

Do not preprocess include and exclude differently.

---

# Part F: FeedManager / FanOut

Keep the important discovery from the first #154 implementation:

FeedManager re-checks KeywordSubscribe filtering during actual insertion.

Therefore all KeywordSubscribe call sites that need URL/hashtag semantics must receive the Status/prepared matching source, not stale `status.searchable_text` only.

Review every call to:

- `KeywordSubscribe.match?`
- instance `#match?`

and make them consistent.

Avoid rebuilding the four prepared strings for every subscription.

Cache/memoize by flag combination per status if clean.

Do not change unrelated FeedManager filtering semantics.

---

# Part G: tests to CHANGE from current #154

The current #154 tests encode the old "raw regexp always keeps body hashtags" rule. Replace those expectations.

At minimum add/modify these:

## regexp common preprocessing

1. raw regexp + flags false does NOT match visible hashtag
2. raw regexp + flags false does NOT match URL
3. raw regexp + match_hashtags=true matches visible hashtag
4. raw regexp + match_hashtags=true matches hidden associated hashtag
5. raw regexp + match_urls=true matches ordinary URL
6. raw regexp + match_urls=true matches reference canonical URL / AP URI
7. raw regexp + hashtags=false + urls=true can match URL fragment #foo but not a body hashtag #foo
8. raw regexp source remains byte-for-byte unchanged
9. ignorecase and timeout unchanged
10. exclude raw regexp uses same prepared text

## existing regexp migration

11. pre-existing regexp=true row becomes match_hashtags=true
12. same row becomes match_urls=true
13. pre-existing regexp=false row remains false/false

## normal keyword common preprocessing

14. flags false strips visible hashtag and URL
15. hidden associated hashtag absent when false
16. hashtag true adds hidden tag
17. URL true adds filterable_urls
18. multiword generated keyword cannot bridge a removed hashtag
19. multiword generated keyword cannot bridge synthetic URL/tag separators
20. URL fragment vs associated hashtag remains independent

## API/serializer after #155

21. serializer renders a real KeywordSubscribe without any exclude_home stub
22. match_hashtags and match_urls round-trip via serializer/API

Retain the broad ASCII/CJK/punctuation characterization already added.

---

# Part H: PR body update

Update #154 PR body to remove the old raw-regexp compatibility claim.

Explicitly state:

- regexp source is unchanged, but its matching INPUT is now preprocessed by the same URL/hashtag options as ordinary keywords
- existing regexp rows are data-migrated to match_hashtags=true and match_urls=true
- this intentionally grants existing regex subscriptions URL matching
- newly created rows default false/false
- hashtag-off masks visible hashtag spans before both keyword and regexp matching
- URL-off supplies URL-stripped material to both modes
- hashtag-on adds associated hidden hashtag tokens
- URL-on uses Status#filterable_urls
- exclude_keyword uses exactly the same prepared text
- #155 fixed the stale serializer field and #154 no longer stubs it

Keep the CJK percent-encoded URL issue as an explicit follow-up, not in #154.

---

# Part I: CJK URL decoding remains OUT OF SCOPE

Do not fix percent-decoded URL matching in #154.

Keep/update the characterization showing current behavior:

```text
https://example.com/東京
-> filterable_urls currently yields an encoded URL form
-> keyword 東京 currently does not match that URL form
```

Add a Follow-up note that a separate PR will provide a human-readable/safely decoded matching representation while preserving canonical encoded URL behavior.

---

# Validation

Re-run all focused #154 specs after rebasing on #155.

Especially:

- keyword subscribe model characterization
- revised matching matrix
- FanOut keyword subscribe delivery
- FeedManager keyword-subscribe paths
- settings controller
- API controller
- real serializer spec
- Status filterable text/url specs

Update exact RSpec and RuboCop results in #154.

Delete this temporary follow-up task file before final PR diff.
