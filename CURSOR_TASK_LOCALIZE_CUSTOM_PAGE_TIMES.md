# Cursor task: display custom moderation / Follow Import page times in browser-local time

## Why

Several pages added by our recent Fedibird PRs render timestamps with Rails `l(...)`.

Mastodon keeps Rails `Time.zone` at UTC by default, so those custom pages currently show UTC even when the operator/user is browsing in JST or another local timezone.

Mastodon already has an established browser-local formatting mechanism in `app/javascript/packs/public.js`:

```js
document.querySelectorAll('time.formatted')
```

Each `<time class="formatted" datetime="...">` is parsed with JavaScript `Date` and rendered by `Intl.DateTimeFormat`, so the displayed value uses the viewer's browser-local timezone and locale.

Use that existing mechanism.

Do NOT change persisted timestamps, service/API JSON timestamps, Rails Time.zone, application-wide timezone configuration, or analytical cutoff semantics. UTC remains the storage/computation interchange basis. This PR is presentation-only.

## Base / branch

Work on:

`fix/localize-custom-page-times`

Base commit:

`b0af350c3998074701b296d679e3c66c5ce1c029`

(PR #144 merged)

## Scope

Audit and fix the custom UI pages added by our moderation / Follow Import work, specifically at least:

### Follow Import progress page (#56)

- `app/views/settings/imports/show.html.haml`
- current timestamp:
  - `row[:occurred_at]`

This Settings page uses `Settings::BaseController` with the `admin` layout, which loads `public.js`, so `time.formatted` is available.

Replace server-side `l(row[:occurred_at])` display with browser-local `time.formatted` markup.

### Behavioral metrics admin UI (#41)

- `app/views/admin/moderation_metrics/show.html.haml`
- `app/helpers/admin/moderation_metrics_helper.rb`

Custom displayed timestamps include:

- metrics `generated_at`
- window metric `first_negative_signal_at`
- Follow Import `latest_import_at`

Any timestamp emitted from `format_moderation_metric(..., 'time')` must use the same browser-local `time.formatted` representation rather than Rails `l(...)`.

Preserve nil / em-dash behavior.

### Moderation evidence admin UI (#38)

- `app/views/admin/moderation_evidence_snapshots/index.html.haml`
- `app/views/admin/moderation_evidence_snapshots/show.html.haml`
- `app/helpers/admin/moderation_evidence_snapshots_helper.rb`

Custom displayed timestamps include at least:

- snapshot `created_at`
- snapshot window start/end
- moderation action `performed_at`

Change these to browser-local formatting.

For the snapshot window helper, preserve the current shapes:

- start – end
- … – end
- all-time

but render each actual timestamp as a `time.formatted` tag.

## Preferred markup / semantics

Follow existing Mastodon server-rendered pages such as admin reports:

```haml
%time.formatted{ datetime: timestamp.iso8601 }
```

Do not add custom JavaScript if the existing `public.js` behavior is sufficient.

Do not hard-code JST, Asia/Tokyo, server timezone, or a numeric offset.

"Local time" in this PR means **the viewer's browser-local timezone and locale**, matching Mastodon's existing `time.formatted` behavior.

### ISO strings from analysis hashes

Some custom services return ISO8601 strings rather than Time objects, e.g. `generated_at`, `latest_import_at`, `first_negative_signal_at`.

Parse defensively using the existing semantics, then put a canonical ISO8601 value in the `datetime` attribute.

Do not alter the underlying service output.

### No-JS fallback

Existing Mastodon markup often leaves `time.formatted` empty and lets `public.js` fill it. Follow the established project convention rather than inventing a separate timezone conversion layer.

If you choose to include fallback content, it must not reintroduce misleading UTC as the normal rendered value and must not conflict with public.js replacing text/title.

## Audit boundary

The immediate user request is about pages added by our PR work.

At minimum inspect all timestamp rendering in the custom files from PRs:

- #38 Admin moderation evidence view
- #41 Admin behavioral metrics UI
- #56 Follow Import progress UX

If another custom moderation/Follow Import server-rendered page from our recent PRs displays timestamp values using `l(...)` or raw UTC text, include it if it is clearly part of the same issue.

Do NOT turn this into a site-wide rewrite of all Mastodon date rendering.

Existing upstream/core pages that already use `time.formatted` are reference behavior, not targets for modification.

## Important non-goals

Do NOT change:

- DB timestamp storage
- ActiveRecord timezone behavior
- `config.time_zone`
- service JSON timestamps
- moderation ledger timestamps
- Follow Import execution semantics
- backtest `observation_end`
- campaign `started_at` / `ended_at` calculations
- mailer timestamps unless they are accidentally in scope because a modified helper is shared (prefer not)
- API serializers
- locale timezone names
- user preference schema
- JavaScript date formatter globally

No migration.

## Tests

Update/add focused tests for presentation helpers/views as appropriate.

At minimum cover:

1. Follow Import progress timestamp renders as `time.formatted` with ISO8601 `datetime`
2. behavioral metric time value renders as `time.formatted`
3. behavioral metrics generated_at uses `time.formatted`
4. behavioral metrics latest_import_at uses `time.formatted`
5. nil time metric remains em dash
6. moderation evidence created_at uses `time.formatted`
7. moderation action performed_at uses `time.formatted`
8. moderation snapshot full window renders two formatted time tags with separator
9. end-only window preserves ellipsis + formatted end tag
10. all-time window remains unchanged
11. datetime attributes preserve the correct absolute instant (ISO8601), with no manual JST offset mutation
12. no service/model timestamp semantics change

Prefer helper specs for helper-generated tags and request/controller/view specs where existing coverage is practical.

Run existing specs for the modified areas.

## Validation

Run at least the focused specs corresponding to modified files, likely:

```bash
bundle exec rspec spec/helpers/admin/moderation_metrics_helper_spec.rb
bundle exec rspec spec/helpers/admin/moderation_evidence_snapshots_helper_spec.rb
bundle exec rspec spec/controllers/settings/imports_controller_spec.rb
```

If you add or modify view specs, run them too.

Run RuboCop on all modified Ruby/helper/spec files.

If HAML lint tooling exists in this branch/project and is routinely used, run it for modified HAML; otherwise do not introduce new tooling.

## Manual reasoning check

Confirm that the relevant pages load `public.js`:

- admin pages via `layouts/admin`
- Settings import page via `Settings::BaseController` -> `layout 'admin'`

The browser then formats `datetime` using `Intl.DateTimeFormat`, therefore a browser in JST displays JST while another browser displays its own local timezone.

## PR

Create one Draft PR against `fedibird`.

Suggested title:

`Display custom moderation times in browser-local timezone`

PR body should explicitly state:

- presentation-only
- uses existing Mastodon `time.formatted` / `public.js`
- browser-local timezone + locale
- no hard-coded JST
- UTC storage/service semantics unchanged
- pages covered: Follow Import progress, behavioral metrics, moderation evidence
- no migration

## Final cleanup

Delete this handoff file before completion and make sure it is absent from the final PR diff.

## Completion report

Return:

- Draft PR URL / number
- head SHA / base SHA
- exact changed files
- every timestamp surface converted
- any custom page audited but already correct / unchanged
- exact test results
- exact RuboCop result
- any limitation or browser-JS dependency
