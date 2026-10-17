# Embedded Rails filter settings

The React route `/web/settings/filters` mounts a settings column with a fixed
`filters` registry entry (`/filters?embedded=1`). It does not replace the WebUI
root, columns container, Redux store or Composer implementation. The existing
columns container records observed React PUSH origins by history entry key. Back returns to that safe originating React entry; direct entry or
unavailable history falls back to Home / Getting started. External referrers and
query/state-supplied return URLs are not used. Child links and successful saves
use location.replace(), so Rails navigations do not add joint-history entries.
Browser Back/Forward controls the React route. The source window scroll is
captured before settings can clamp it, then restored through the existing
ScrollContext callback when returning to that source entry. A source-post anchor
settles transient loading-row/browser adjustments for at most one second; wheel,
touch, pointer, key, resize or another route immediately ends that correction.
The normal Rails page remains available through Open in a new tab.

## Security and navigation

Filter mode is explicitly opted into by `FiltersController` and
`Filters::StatusesController`. The two posting-style settings controllers now
share this concern with a separate screen marker and administrator check; see
[their contract](embedded-posting-style-settings.md). Literal `embedded=1` selects a separate compact layout. Existing
partials, public/admin packs (Rails UJS, deletion confirmation, cocoon keyword
rows, emoji picker and batch selection), authentication, account ownership,
CSRF verification and private/no-store caching remain in use.

After a successful, authenticated, functional-user **HTML render**, the concern
clones the request's CSP and changes only `frame-ancestors` to `'self'`; XFO is
`SAMEORIGIN`, overriding production's `DENY` on that response. Redirects, errors,
non-HTML requests, normal filter pages, login and unrelated settings retain
`frame-ancestors 'none'`. The global initializer and parent frame-src are
unchanged. GETs and validation-error HTML renders can be embedded; mutations
redirect within the filter routes, carrying the explicit mode option.

Links, form actions and pagination carry the mode explicitly on filter paths.
Post/profile links open separately; the child pack makes other non-filter links
open with `_blank` and `noopener noreferrer`. No destination/return URL parameter
is accepted. The parent checks the loaded same-origin filter path, the mode and
the dedicated-layout marker before enabling navigation and passive refresh. It accepts no postMessage events.

There is deliberately no iframe sandbox claim: scripts plus same-origin access
would not provide isolation. Trust comes from existing authenticated Rails code,
the fixed registry and the response-specific framing policy. Session expiry may
produce a browser framing diagnostic for the blocked login response; the parent
shows a fallback and keeps a new-tab sign-in link and retry button available.

## Filter refresh and current posts

Trusted iframe load completions schedule existing `fetchFilters()` with a 300ms
trailing debounce. A separate parent-window request function submits the existing
Rails forms with their FormData, CSRF token, method override and submit button.
Confirmed UJS delete links use the same Rails POST/method/CSRF mechanism.
The parent fetch follows Rails redirects and requests HTML. On response completion
it calls `fetchFilters()` outside the settings component lifetime, including when
the user has already left the column. Pending saves are never cancelled by
unmount or the UI timeout. An earlier passive refresh is not treated as save
completion; older concurrent filter API responses cannot overwrite a newer fetch.
The existing streaming `filters_changed` mechanism also remains active.

Redirected, permitted filter responses cause a replacement iframe GET. An invalid
Rails form renders its existing server-generated main in the already-protected
child document (without replacing its CSP-protected head or executing response
scripts). The existing emoji widgets are reinitialized; delegated Rails/cocoon
handlers remain active. Authentication redirects and error pages are never
inserted. Every intercepted link/save and final replacement GET starts a 15-second
UI timeout. While a save is pending, duplicate submits and retry are suppressed;
Back and the normal new-tab link remain available. After leaving and reentering,
any still-pending parent request continues its completion refresh independently.

A full tab close/reload cannot guarantee completion delivery. If the filter API
is unavailable or its authentication has expired, synchronization cannot be
guaranteed until access is restored; no reload or draft reset is forced. A network failure
can also leave the Rails commit outcome unknown: one reconciliation fetch is
attempted, with no polling or unsafe URL/message permissions; the user can open
the normal page or retry after the request settles. The UI timeout does not prove
a save failed and does not resubmit it. No timeline is reloaded/remounted for sync.

The collection refresh updates existing match references' title/action/context/
expiration and removes deleted filters. Existing status objects retain the
server-supplied `filtered` matches: new/changed keywords and added/removed
individual-post memberships require those posts to be fetched again before all
matches reflect the change. This PR does not scan/refetch every loaded timeline
or reimplement server matching in JavaScript.

## Review checks

1. On a desktop with the advanced multi-column layout, pin two hashtag/list/group
   columns and open their Portable Composers. Enter different text and CWs,
   attach media and leave a post being edited. Record a scrolled timeline position.
2. Open Filter settings from navigation, Getting started or the Compose menu.
   Verify that the existing columns, DOM, drafts and attachments survive entering
   the settings column, saving, and using its Back link/browser Back/Forward.
3. Create a filter; submit an invalid blank title, add/remove keyword rows, set
   whole-word matching, contexts, action and expiration, save, edit and delete it.
   Confirm Rails confirmation dialogs and emoji picker still work.
4. Add a post through the existing filter modal; follow its settings link, manage
   the post list, paginate, remove selected posts and submit with no selection.
5. Confirm `/api/v2/filters` is fetched after navigation/save. Check existing
   title/action/deletion changes and the cached-match limitation described above.
6. Open the normal page in another tab: it has the admin sidebar and its original
   framing policy. Post/profile links inside the embedded page open separately.
7. At a 390px mobile viewport, repeat navigation and form editing; test long
   titles/keywords, table scrolling, keyboard navigation, safe areas and themes.
8. Expire the session: login must remain blocked in the frame. Use the new-tab
   link to sign in, then retry without reloading the WebUI.
9. Inspect real CSP/XFO in development and a production-like environment. Verify
   that same-origin framing succeeds, a different origin is rejected, and normal
   filter/login/unrelated settings pages remain unembeddable. An upstream reverse
   proxy must not add a second restrictive CSP/XFO to the embedded response.

Automated request specs cover both normal and embedded flows, production-style
DENY defaults, CSRF, ownership and authentication. Jest covers fixed URLs, frame
validation, refresh coalescing, fallback/retry, ignored messages, route integration
and preservation of primary/portable Composer reducer state. The PR description
records the actual browser checks and any remaining verification separately.

## Review regression checks

- With streaming notifications withheld, submit create/update/delete/status batch
  and leave the React settings route before Rails commits. Release the request
  and check that the parent fetch completes and refreshes the collection.
- Repeat with Rails already committed and the redirected response held before
  iframe load. An initial/passive load fetch must not count as completion.
- Delay an earlier filter API response until after a newer post-save response;
  the old response must not replace the new collection.
- Enter from a hashtag/list/status route, navigate new/edit/statuses and submit
  invalid and valid forms. Child operations must not grow joint history. Back
  and Forward must traverse React routes, preserving source Composer state and
  reading position. Direct entry must use the safe default screen.
- Stall a later child GET: the 15-second failure UI must appear and Retry must
  recover. Stall a save: no automatic duplicate submit or cancellation on timeout
  or unmount; Back/new-tab remain usable and completion still refreshes.

Posting styles now share the opt-in screen infrastructure; see
[Embedded posting style settings](embedded-posting-style-settings.md) for its
administrator boundary, explicit methods, preview and catalog/draft contract.
