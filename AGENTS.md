# Fedibird: guidance for coding and review agents

These rules apply to the repository. Follow the current issue, PR, and explicitly approved design or acceptance criteria. Do not treat an unapproved proposal as permission to implement it. Read the relevant docs for the files you touch; do not load every design document for an unrelated change.

## Project boundaries

- Fedibird is a Mastodon fork. The integration/default branch is `fedibird`, not upstream `main`. Prefer small, reviewable changes that preserve both Mastodon interoperability and intentional Fedibird behavior.
- Rails provides the API and background jobs, React/Redux provides the Web UI, and Node.js provides the streaming service.
- Preserve established REST/ActivityPub field names, types, IDs, visibility and delivery semantics unless an approved task explicitly changes them. Do not claim an ActivityPub/FEP capability without its actual implementation and interoperability evidence.
- Fedibird is not identical to upstream Mastodon: do not assume an upstream feature (for example a local timeline) exists here, or remove Fedibird-specific behavior while applying upstream fixes.

## Working agreement

- Start with the relevant issue, PR discussion, code paths and narrowly relevant documents. Clarify a missing product decision in the issue/PR instead of silently choosing a new user-facing behavior.
- Work on a topic branch. Open a Draft PR while design, implementation, or verification is incomplete; keep the diff focused and document any change in scope.
- An explicit design-approval or test gate must be satisfied before proceeding beyond it. UI changes may require single-column, multi-column and mobile checks, plus real-device verification when requested.
- In the PR, state the intended behavior, tests actually run and their results, risks, and manual or production checks still outstanding. Clearly distinguish locally run tests from GitHub CI and from real-device testing.
- Keep implementation and review responsibilities separate where assigned. Address actionable review findings with code/tests or a reasoned explanation. CodeRabbit's ready-for-review pass is additional review, not an approval to merge.
- Never merge, deploy, change production settings, run production migrations, or execute destructive production operations without explicit maintainer authorization.

## High-impact invariants

- **Security and privacy:** Scope every user-owned API and settings operation to the authenticated principal. Check permissions and visibility at the data boundary; prevent private/direct content, emoji-mute rules, tokens and credentials from leaking through responses, logs, caches, streams, translations or other users' sessions.
- **Federation:** Treat remote ActivityPub data as untrusted. Preserve canonical actor/object identities, JSON-LD meaning, signature and authorization behavior, public/private audience boundaries, and compatibility with non-Fedibird servers. Review additions to Group, reaction, quote and external-bridge flows for backward compatibility.
- **Data and migrations:** Tables such as statuses and status_stats are very large in production. Avoid full-table rewrites, long blocking locks, unconditional backfills and per-row queries. Evaluate lock duration, concurrent indexing, phased constraints, batch sizes, rollback and production deployment sequencing. A green unit test is not evidence of safe migration runtime.
- **Frontend behavior:** Guard asynchronous requests, timers and subscriptions against stale results, unmounts and account changes. Consider single/multi-column and mobile layouts, keyboard/screen-reader accessibility, scroll behavior, dark/light themes, and the cost of startup network requests.
- **Emoji/translation/content:** Preserve visibility and mute guarantees across status text, CW, quotes, translations, notifications, ALT, ARIA and reactions. Test disabled/default preferences and error/retry states; a CSS-only hide is not sufficient for content that must not exist in the accessible DOM.
- **Settings:** Preserve absent/default versus explicitly stored false values and reader/writer consistency. For settings catalog changes, regenerate and check `docs/settings_service/catalog.yml` with the repository scripts rather than manually patching generated entries.
- **Tests:** Prefer focused regression coverage for authorization boundaries, older API behavior, disabled states, error paths, races and performance-sensitive queries; avoid unrelated refactors just to satisfy a review suggestion.

## Toolchain and focused verification

- Ruby version: `.ruby-version` (currently 3.2.8). For JavaScript use Node.js 20 or newer as required by `package.json`; the legacy `.nvmrc` value does not satisfy that requirement. Use Yarn with the checked-in lockfile.
- Cursor Cloud Agent setup is in `.cursor/environment.json` and `.cursor/install.sh`; those files describe a development environment, not permission to touch production.
- Run relevant checks for changed files. Examples (replace the sample paths):

```sh
RAILS_ENV=test bundle exec rspec spec/path/to/example_spec.rb
bundle exec rubocop app/path/to/changed_file.rb

yarn jest app/javascript/mastodon/path/to/example-test.js --runInBand
yarn eslint app/javascript/mastodon/path/to/changed_file.js
yarn sass-lint > /tmp/fedibird-sass-lint.log 2>&1

ruby script/build_settings_service_catalog.rb
ruby script/check_settings_service_catalog.rb
git diff --check
```

- Only run the catalog scripts for relevant settings changes. Redirect verbose lint logs to a file when helpful. If a check cannot run, state the reason and leave it unverified; never report an unrun check as passing.
- Consult the relevant `docs/` design for the feature being changed (for example ActivityPub Group, composer drafts, emoji mutes or Settings Service). Existing CI workflow and repository configuration take precedence over generic upstream instructions.
