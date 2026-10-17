# Embedded posting style settings

Issue #479 adds the administrator-only React route
`/web/settings/posting-styles` (React `/settings/posting-styles`). The posting
style picker and Getting started settings section link there. The existing
columns, Redux store and Composer tree remain in place. The settings header
retains a normal Rails link opening in a separate tab.

This extends the filter embedding protocol from #461. The fixed registry has two
separate screens, `filters` and `postingStyles`; it accepts neither arbitrary
URLs/actions nor messages from another window. React uses a different component
key for each screen. Existing return-origin history and finite scroll protection
are shared. Direct visits retain the standard Home/Getting started fallback.

## Allowed Rails operations

All URLs must have the current origin. Posting-style URLs reject credentials,
fragments, encoded/noncanonical IDs, duplicate or unexpected query parameters,
and IDs outside the positive signed-bigint range. `embedded=1` is literal.
Only the assignment index accepts `page` (1–2147483647) and positive
`user_posting_context_id`.

| Path under `/settings` | HTML navigation | Mutation |
| --- | --- | --- |
| `user_posting_contexts` | GET index | POST create |
| `user_posting_contexts/new` | GET | — |
| `user_posting_contexts/:id/edit` | GET | — |
| `user_posting_contexts/:id/confirm_destroy` | GET confirmation | — |
| `user_posting_contexts/:id` | — | PATCH update / DELETE destroy |
| `user_posting_contexts/:id/duplicate` | — | POST |
| `user_posting_context_assignments` | GET index/filter/pagination | — |
| `user_posting_context_assignments/:id/release` | — | POST |
| `user_posting_context_assignments/:id/decline` | — | POST |
| `user_posting_contexts/preview` | Never an iframe destination | Existing POST JSON/AJAX only |

The parent intercepts real HTML forms and carries their FormData, CSRF token,
method override and submit button. Preview uses the existing admin pack's JSON
fetch, including its generation/abort handling, and is never submitted as HTML.
Rails redirects, links, form actions, preview data URLs and pagination preserve
embedded mode explicitly. Unrelated links open separately; forbidden forms are
blocked instead of submitting the iframe to another settings/login page.

## Authorization and framing

The existing opt-in `EmbeddedFilterSettings` concern is safely shared by the two
filter controllers and the two posting-style controllers. Its existing helper
names are retained for filter compatibility; it now supplies a fixed screen
marker, heading and home link to the shared layout.

Posting controllers still require a functional signed-in administrator and scope
records to `current_user`. The existing API retains its administrator check.
Non-administrators have no entry or iframe, including direct React-route access.
There is no change to API schema, database migrations or the global CSP.

Only a successful status-200 HTML render with literal `embedded=1` gains CSP
`frame-ancestors 'self'` and XFO `SAMEORIGIN`. Normal pages, JSON preview,
redirects, forbidden/not-found/CSRF responses, login and HTML 409 responses retain
`frame-ancestors 'none'` and production's DENY default. Other CSP directives and
private/no-store caching remain intact.

Validation HTML (200/422) and stale-lock HTML (409) can be rendered only inside an
already protected document: the parent verifies response URL/method, HTML media
type, screen marker and main element, then replaces only `main.embedded-settings`.
It never adopts a response head/CSP or executes response scripts. Original error
messages and lock_version remain visible. Preview, choice panels, card menus and
emoji widgets are rebound on the replacement form. Before replacement, the old
preview binding removes listeners, cancels its debounce/transport and advances
its generation; even a transport ignoring abort cannot paint the new form. A different-screen marker or
login response is rejected. Ready/load events for the same document do not detach
its existing handlers. Save requests are not mistaken for navigation success.

## Completion and catalog ordering

The HTML mutation runs in the parent window and is never aborted by leaving the
column or by its 15-second UI timeout. On completion, including the final Rails
redirected response, the parent forces a full
`GET /api/v1/fedibird/user_posting_contexts`. Passive iframe loads also debounce
refreshes, but are not substitutes for completion. A network error triggers one
reconciliation, with no mutation retry or polling. Reentry also refreshes.

`fetchUserPostingStyles({ force: true })` starts a new read even while an older
read is loading. Per-store request serials reject older SUCCESS and FAIL actions.
Reads have a 15-second timeout. Invalid/non-array responses are failures. A failed
refresh retains the previous catalog and exposes Retry; a confirmed successful
empty array alone represents an empty catalog. Existing options remain usable
while a loaded catalog is refreshing or a refresh failed.

A pending posting-style mutation is tracked per store/dispatch across column
unmount and remount. Duplicate submits and Retry are blocked until it settles;
Back/new-tab remain available. Successful HTML renders and 409 validation pages
are distinct; neither timeout nor conflict is reported as a successful save.

After a mutation reconciliation, cached place-default assignments are marked
idle and their read generations advance. Mounted existing controllers perform
one fresh read; closed places wait until next mount. A default write already in
progress is retained, and its existing generation ordering continues to protect
it from older reads. This reflects DB deletion-to-none and release/decline
without retaining obsolete cached default flags. No assignment is written by
this synchronization path.

## Draft contract

Catalog refresh does not dispatch style COMMIT, destination changes or any
Composer reset. Primary and Portable selectors continue to reference the same
catalog, with the existing surface candidate filter and administrator boundary.
Open menus receive updated names/icons/additions/deletions and destination
eligibility. A selected style's snapshot remains authoritative for that draft's
label and applied values even after its catalog record changes or disappears.
Only an explicit subsequent selection applies the new definition.

Body, CW, media, poll, language, visibility, Group/required tags, edited status,
manual overrides, selectionOrigin and defaultsSettledSurface are not rewritten.
The existing controller's one-time-per-surface default selection contract is
unchanged. A settled untouched draft does not absorb a newly created style or a
new default after cache reconciliation. Initial unresolved context/default
loading retains its existing behavior.

## Validation and remaining boundaries

Request specs cover existing filter embedding and administrator/normal/anonymous/
foreign records, real CSRF, CSP/XFO (including production DENY), CRUD, duplicate,
delete-to-none, filtered/paged assignments, release/decline, invalid forms, stale
409s and JSON preview. Controller/API specs cover the existing normal contracts.
Jest covers fixed routes/queries/methods, cross-screen rejection, duplicate load,
completion after departure, duplicate saves/reentry, network failure, delayed
catalog responses, retained choices on failure, stale assignment reads,
three open primary/portable menus, snapshot/draft identity, surface restrictions
and settled automatic selection. Existing filter/Back/Forward/scroll tests remain.

Commands and actual totals, base/HEAD and browser coverage are recorded in the
Draft PR. Browser checks use local development fixtures, never production data.
Real mobile Safari, cross-tab live synchronization and prolonged network/soak
behavior are outside this change. Closing/reloading the entire parent tab cannot
guarantee delivery of the completion refresh; reentry explicitly refreshes.

## Executed validation (2026-10-17 JST)

Starting base/HEAD: `92ec61da7cb491c61dbb14e09ebfd9397185d9f1` on
`origin/fedibird`. Final implementation HEAD is recorded in the Draft PR.

- Related Jest: **12 suites / 167 tests passed**.
- Full Jest: **225 suites passed / 11 failed**, **2043 tests passed / 13 failed**,
  **13 snapshots passed**, 79.48s. The 11 failing suites were rerun with modified
  existing JS temporarily restored to the starting base. All 13 failing assertion
  fullNames matched; the implementation was restored. Existing failures involve
  compose submission/portable composer/compose target, emoji, Mix navigation,
  custom emoji titles, translation-bar visibility, and Jest collecting the split
  helper plus three streaming Node-test files. There are no new failing cases.
- Related RSpec: **74 examples / 0 failures**, 16.52s (3.88s loading), across the
  two embedding request specs, posting-style/assignment controllers and both API
  controller specs. Production-style DENY defaults and real CSRF are included.
- Changed Ruby: RuboCop **4 files / no offenses**. Changed JS: ESLint **0 errors**;
  one pre-existing `no-nested-ternary` warning in UI's default redirect remains.
  `git diff --check` passes.
- Development/test asset builds succeeded. Final production webpack succeeded
  in **73.29s wall time**. Existing Sass/Browserslist/asset-size warnings remain.
  No dependency or schema changes are included. Local development DB setup's
  generated annotation/schema edits were discarded.

Actual Chromium against authenticated **local Rails + full WebUI**, with a
throwaway administrator fixture:

| Configuration | Confirmed operations |
| --- | --- |
| English, 1280px | Existing validation HTML, preview after form replacement (managed hashtag), create, parent Back with POST held until after departure, completion catalog GET, same Composer DOM and Immutable draft object, duplicate, save, delete confirmation/deletion and catalog removal |
| English, 390px | Embedded form, main clientWidth/scrollWidth both 390px |
| Japanese, 1600px / three columns | Japanese title, actual stale lock 409 after another authenticated update, original lock retained, no false success/fallback; filtered assignment index, visible Next pagination, decline/release, same primary draft object |
| Preview response race | Held the old preview response while deliberately ignoring abort; validation replaced the form, its old signal was aborted, the released stale response did not paint the new form, and a fresh real Rails preview succeeded |
| Japanese, 375px | Embedded form, main clientWidth/scrollWidth both 375px; real Emoji picker opened |

Authenticated HTML checks confirmed embedded CSP `'self'` + SAMEORIGIN and
normal-page CSP `'none'`. Production DENY was verified by RSpec, not by deploying
a production server. The held-save test saw a completion catalog GET after Back;
passive refresh did not substitute for completion. Three simultaneous primary/
portable menus and surface-specific filtering were verified in Jest, not in a
three-Composer browser session.

Remaining browser boundaries: no real mobile Safari/touch keyboard, custom emoji
upload/remote Group discovery, actual media posting, prolonged soak, or session
expiration during a live save. Authentication/error responses and delayed/out-of-
order/failure paths have request/Jest coverage. No cross-tab push sync was added;
embedded completion and reentry refresh are guaranteed subject to API access.
The entire-tab-close limitation above remains. The PR stays draft for review;
no merge or production deployment is performed.
