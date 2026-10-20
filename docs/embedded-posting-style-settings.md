# Embedded posting style settings

`/web/settings/posting-styles` mounts the existing settings column with the fixed
`postingStyles` screen. The Composer menu and navigation panel link to it only
for administrators; the column also checks the administrator flag before rendering
an iframe. Open in a new tab keeps the normal Rails UI and framing policy.

## Rails, navigation and framing

The two posting style/assignment controllers opt in to `EmbeddedRailsSettings`
through `EmbeddedPostingStyleSettings`. The filter concern uses the same layout
and framing implementation with its existing `filters` marker and routes.
Authentication, administrator authorization, current-user scopes, CSRF, form
validation, optimistic locking, duplication, deletion confirmation and assignment
pagination/release/decline remain in their existing controllers and forms.
No new table, migration, or API field is introduced. The existing assignment
table stores the user’s usual style at `surface_kind: global`, `surface_key:
default` only. That pair is not a composer surface, a place count, or a place
list row. Other global keys are rejected. unset and none both mean no usual
style. A disabled reference stays unavailable and is not replaced.

A composer remembers a separate usage duration. Choosing another style, including
an explicit “no style”, lasts for this post unless the user chooses to keep it.
A successful new post or a newly accepted scheduled post returns a one-time
choice to the usual selection. Keeping a choice retains the style only; it does
not retain that post’s hashtag suppressions. Failed sends, edits of an existing
post, and reply cancellation do not perform that return. Stale success and
assignment responses are ignored when the composer instance, draft text, media,
selection generation, surface, or sender no longer match.

Only literal `embedded=1`, functional-user, authorized HTML renders with status
200 receive response-local `frame-ancestors 'self'` and `SAMEORIGIN`. Normal
settings, redirects, login, unauthorized/foreign resources, JSON previews and
409/error responses keep the existing framing headers and `frame-ancestors
'none'`. Conflict HTML includes the dedicated layout marker, but cannot be
loaded as a new framed document: the parent inserts only its server-rendered
main into the already-protected document, retaining the original head. Both
validation and conflict reinitialize the existing preview and emoji widgets.
An in-flight preview is scoped to its original main so it cannot overwrite a
replacement form's preview. Preview FormData excludes the edit form's `_method`
so Rack keeps the preview request as POST; saves retain PATCH/DELETE overrides.

The registry checks screen, origin, marker, literal mode, positive numeric IDs,
unique supported query parameters (`embedded`, `page`, `user_posting_context_id`)
and existing route/method combinations. Only index/new/edit/confirm-destroy and
assignment index are frame GET destinations. Create, PATCH/PUT update, DELETE,
duplicate, release and decline use their real Rails methods. The collection POST
preview stays a JSON AJAX operation owned by the existing widget; it is never a
frame destination or a catalog mutation. There is no member preview/show route
in the current Rails routes, so none is added to the allowlist.

Internal links/forms explicitly carry the mode. Unexpected forms are blocked;
other content links open separately with noopener/noreferrer. Neither screen
accepts arbitrary return paths or postMessage commands. Child navigation uses
replacement history. The existing observed React history/scroll contract covers
both screens, leaving timeline and Composer instances mounted.

## Catalog synchronization and drafts

The parent-window mutation request is independent of the column lifecycle and
is never aborted on Back, unmount or the UI timeout. After the Rails response
(including redirected GET) completes, it forces a full posting-style catalog
GET. Passive frame loads also coalesce refreshes, but do not replace mutation
completion. Ambiguous network failures trigger one reconciliation, never a
mutation resend. Duplicate submissions and Retry stay disabled while saving.

Every catalog request carries an ID. Force starts a newer request even during
loading; older successes/failures cannot change the latest catalog. Failed or
malformed responses retain the last good collection; an actual successful empty
array is the only fetched result representing all styles being deleted. Pickers
retain loaded candidates during refresh and after failure, with a retry notice.
Primary and Portable Composers read the same collection, retaining their existing
surface restrictions. Catalog actions never apply styles or update selected
snapshots, draft fields, manual overrides, selection origin or settled defaults.
A deleted selected style is still represented by the applied snapshot until the
user explicitly chooses again.

Every posting-style reconciliation invalidates all cached assignments before
starting the catalog GET. Generation advances and old defaults are cleared for
all places, but only distinct surfaces with mounted administrator Portable
Composer controllers are read immediately. Each controller registers its own
consumer ID and removes it on unmount or surface/edit-mode changes, so two
controllers sharing a place keep it active until the last one leaves. Reads
coalesce through the normal loading guard. Closed places stay idle and are read
lazily on next use; 500 cached places do not cause 500 reconciliation GETs.
Delayed pre-boundary GET/write responses cannot restore an invalidated default.
A failed GET remains non-authoritative so new Composers wait for explicit retry.

The per-surface writePending/writeGeneration lock is separate from fetch status
and survives invalidation, idle/loading/ready transitions, and GET failure. New
PUT/DELETE operations remain blocked until that same HTTP write settles; the
picker stays busy and automatic default selection waits too. If a read or refresh
superseded the write's response, its finally starts a fresh server read before
releasing the lock. The write is never resent. Existing evaluated Composers keep
their settled surface, snapshot and draft; new Composers use the reconciled choice.
A full tab close/reload cannot guarantee completion delivery. Other-tab changes
are picked up on embedded reentry, without cross-tab monitoring or streaming.

## Verification

Automated tests cover route/method/query and marker isolation, filter regression,
Back/Forward origins, validation/409 rendering, completion refresh after departure,
ambiguous failure, response ordering, multiple open Portable menus, surface
filtering, full primary/Portable draft and snapshot preservation, administrator
visibility, preview rebinding and stale preview isolation. Real Redux integration
with mounted controllers/pickers covers two evaluated drafts, none/unset/deletion,
new-Composer automatic selection, delayed GET/write success/failure, ambiguous
HTML completion and assignment reconciliation failure, write serialization
across refresh (success/failure), 500-place lazy invalidation, shared consumers
and registration cleanup. Request specs exercise
real routes, production-style DENY defaults, ownership/authentication, JSON
preview, CRUD, assignment paging/release/decline and real CSRF.

Actual commands, results and browser coverage are recorded in the Draft PR.
Production reverse-proxy framing behavior must still be checked in the target
environment; an additional restrictive upstream header can prevent embedding.
