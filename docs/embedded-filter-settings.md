# Embedded Rails filter settings

The React route `/web/settings/filters` mounts a settings column with a fixed
`filters` registry entry (`/filters?embedded=1`). It does not replace the WebUI
root, columns container, Redux store or Composer implementation. The column's
Back link returns to Home in the single-column interface or Getting started in
the multi-column interface. Browser history also includes iframe navigations.
The normal Rails page remains available through Open in a new tab.

## Security and navigation

Only `FiltersController` and `Filters::StatusesController` include the opt-in
concern. Literal `embedded=1` selects a separate compact layout. Existing
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
the dedicated-layout marker before refreshing. It accepts no postMessage events.

There is deliberately no iframe sandbox claim: scripts plus same-origin access
would not provide isolation. Trust comes from existing authenticated Rails code,
the fixed registry and the response-specific framing policy. Session expiry may
produce a browser framing diagnostic for the blocked login response; the parent
shows a fallback and keeps a new-tab sign-in link and retry button available.

## Filter refresh and current posts

Trusted iframe load completions schedule existing `fetchFilters()` with a 300ms
trailing debounce. Closing the column flushes a queued refresh. The existing
streaming `filters_changed` mechanism also remains active. Nothing reloads or
remounts the timeline to obtain fresh matches.

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
