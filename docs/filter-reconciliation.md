# Mounted-surface filter reconciliation (P3)

Issue #468 builds on the P1 batch API and P2 generation/overlay in
`filter-match-overlay.md`. Rails evaluates matches. This implementation collects
wrapper IDs, calls P2 and preserves list geometry; it does not match text in JS,
import API match results as statuses, reload timelines or modify their ID arrays.

## Ownership and coverage

`ScrollableList` owns a `FilterSurface` for each mounted instance, independently
of `scrollKey`. Two columns, or Live/History panes with the same IDs, keep separate
registrations, priority and scroll snapshots. Changing route session key, scrollKey, DOM node or
scroll target destroys the old surface. Media-modal navigation retains the
reading session. A per-list history listener handles reused PureComponent
routes and is removed on unmount. Unmount removes input/scroll listeners,
finite animation frames and registration. The existing article observer can
reconnect to a changed document/column root without losing its observed nodes.

`StatusList` registers its displayed IDs, additional source-owned IDs, featured
IDs and immediate-feed IDs. Ordinary timeline containers also pass retained
pending IDs; Live keeps ownership beyond its displayed window. IDs are canonical
positive signed-bigint strings; safe integer inputs can be converted, unsafe JS
numbers and null gaps are excluded. Wrapper and original remain distinct IDs.
The existing article observer supplies independent priority even with
`trackIntersection=false` or status intersection polling disabled. Scroll events
refresh geometry only for near rows, with one animation frame per surface.

All callers of StatusList inherit collection: Home/List/Public/Remote/Domain/
Hashtag/Group/Limited/Personal, account timelines, bookmarks/favourites and the
existing normal/split timeline list routes. Their existing context props and
per-source Mix contexts still reach `makeGetStatus`.

Collection does not invent a missing rendering context. Some existing auxiliary
lists (for example bookmarked/favourited/emoji-reactioned statuses) pass no
timelineId and retain their contextless selector behavior. They can share
reconciled IDs with other owners but do not newly hide rows just because this
scheduler evaluated them. Account timelines supply `account`.

Mix explicitly supplies **pre-filter** source/live/frozen-history/pending IDs.
`mixTimelineView` overlays only current-generation confirmed filter IDs onto its
source results before building the merged view. Nonmatches can therefore restore
IDs omitted by old hide filtering. Source membership/order/frontiers, tombstones,
visibility preferences and pending suppression remain intact. Hide/warn is still
context-sensitive: home can be hidden while the same wrapper remains present
through public. Expired definitions and the viewer's own posts are excluded,
consistent with P2. No source array is rewritten.

Notifications collect `notification.status` for status-bearing notification types
from items and pending items, with a separate notification-row-to-status mapping.
Follow/admin/report notification IDs are never used as status IDs. For all nine
status-bearing types (`mention`, `status`, `poll`, `favourite`, `reblog`,
`scheduled_status`, `emoji_reaction`, `status_reference`, `update`), both the parent
hotkey selector and nested StatusContainer use `notifications` context. Existing
notifications follow hide/warn changes immediately: hide removes the post body,
while the non-mention notification heading remains. A mention renders only the
post, so hide leaves its article empty. Warn retains the post warning and the
same hotkey target. Favourite/boost/CW hotkeys have no status target after hide;
notification-heading navigation/mention actions remain available. Self-authored
posts retain P2's exclusion, including favourite/reblog notifications. Non-status
types (follow/follow request/followed/admin signup/report) have no post to filter.
Arrival-time suppression, unread markers/counts, notification settings, sounds
and alerts are unchanged; their actions/reducers are not modified.

**Explicit exclusions:** the compose/search results component and the standalone
status-detail tree do not use StatusList/ScrollableList. They are not registered
by this change, including replies rendered only in that detail tree. Their
existing contextless central-status selection and independent scrolling are not
rewritten. Tests preserve that selector contract and verify no automatic POST
without a registered surface. This is a remaining P3 adapter gap, not a claim of
complete WebUI surface coverage. Embedded quotes, media/modals and static/public
status pages are likewise not independent owners. A narrow future adapter must
preserve the detail route's intentional central-post and navigation behavior.

## Scheduling, initial policy and bounds

`filterReconciliationMiddleware` installs one lazily used scheduler per Redux
store (the current signed-in WebUI session). Registration is primarily driven by
mounted views, never a global statuses/timelines scan. Reducers and selectors
continue to own status content and filter interpretation.

P2's row selector shares its active definition subset per canonical collection
and server context until the next absolute expiry. Unrelated Redux updates no
longer force every row to recompute filter presentation. Definition changes,
expiry and backward clock changes invalidate that subset; no timer is added.
Article intersection notifications are also collected into one priority frame
instead of reading layout after each virtual row updates.

- Missing complete baseline: one immediate-demand GET after an 80ms coalescing
  boundary, with a 15s transport timeout. Failure waits for a recovery event.
- Initial generation 0 trusts freshly imported FilterResults. It does not POST
  every initial load. A material edit invalidating an existing overlay is still
  rechecked. After any accepted generation change, mounted/newly mounted owners
  are eligible even if `needsReconcile` was already true. That sticky flag is
  never used to decide completion.
- Visible IDs first, near IDs second, retained/hidden/pending IDs third; round
  robin across surfaces within each tier. IDs deduplicate across views and
  contexts, while render contexts remain independent. New counters, reactions,
  translations or stale filtered metadata do not invalidate confirmations.
- At most **100 IDs / POST**, **one POST in flight**, **80ms between drains**
  (plus transport latency), and a **15s timeout**. This also bounds response/UI
  update cadence for match batches. Definition/presentation changes retain P2's
  immediate interpretation rather than delaying known hide/expiry semantics.
- Retain at most **2000 distinct candidate IDs**, matching P2 capacity; each
  surface contributes at most 2000 ordinary candidates plus its current near/
  visible IDs. There are at most **64 surfaces**, one scheduler timer and one
  bounded attempt record per retained ID. Near rows outside the ordinary window
  can replace low-priority ownership. IDs beyond the selected 2000 are deferred
  until viewport/ownership changes, not continuously cycled through the overlay.
  Thus there is no promise to reconcile an arbitrarily large background backlog
  without revisiting it. Fairness applies within this explicit capacity.
- Current confirmed results are reused. Attempts record their generation and P2
  entry identity. Material invalidation permits new work; edits while in flight
  and newer generations wait for the bounded old request to settle, then use P2
  serial/generation rejection. A status/body returning to its previous value
  cannot make an old response authoritative. No mutation request is aborted.
- Release IDs no longer selected via P2 clear, after accounting for all owners.
  Final unmount immediately releases timers/listeners/attempts/retained entries.
  An already running read can settle within its timeout; its cleared entries
  reject the result. There is at most one such transport, with <=100 IDs.

The 2000-row capacity and stable selection are deliberate. Continually evaluating
rows outside it would evict visible confirmations and create an endless request
cycle. No global reverse-index lifetime or persistent cache is added.

## Failure and recovery

`[]` is a confirmed nonmatch; unavailable is not. Failed/unavailable IDs receive
one attempt per generation/content identity until an explicit recovery event.
Visible revisit, document visibility, online and user-stream reconnect can retry
a failed ID after at least 60s. These events can retry a failed baseline GET too.
There are no retry/backoff/polling loops or timers running merely because a TTL
elapsed. Hidden documents and navigator-offline sessions pause new work.

HTTP 429 pauses the whole scheduler until Retry-After (seconds or HTTP date), or
60s if absent/invalid. 401/403/422 pause it for at least 60s as well. A generation
change does not bypass that pause. Recovery still needs a later event; there is
no timer firing automatically at the deadline. Other failures remain per-ID
suppressed. P2 keeps conservative legacy display during failure/unavailable;
this change never turns an uncertain result into an empty match.

## Scroll and interaction

Before subscribers render, middleware predicts whether a definition or accepted
overlay/clear action changes presentation; unchanged definitions and stale or
identical results skip capture. Status imports compare only presentation/content
fields, and poll imports compare option titles. Counter/vote updates and new
unowned streaming posts do not request a snapshot. Content/FilterResult changes
only prepare owning surfaces, including hidden/prefiltered source IDs and boost
originals. This is a pre-reducer check: after-state notification would be too late
to capture React's old geometry. No full root reduction is performed in preflight.
The existing P2 content invalidation fields are included so rejected confirmations
can fall back to imported results safely.
The surface keeps the first visible `article[data-id]` at its viewport top and
nearby next/previous alternatives, including their pixel offsets. After React
updates it restores the same stable row, or a nearby surviving row, or the
captured scroll offset. Ordered article nodes are located with a binary search
of their bottom edges (including virtual/zero-height rows), followed by at most
five forward and two previous rect reads. Rects are memoized within a capture;
the search performs O(log n) geometry reads rather than measuring every article.
The node list is still enumerated for those rare snapshots. If the bounded
neighborhood has no surviving row, saved-offset fallback applies.
Correction is limited to **two animation frames**. Changes within that window
reuse the original snapshot: both restores measure cumulative movement against
the same offsets, so multiple changes are retained without extra captures.
Re-entering a cached virtual article captures before replacing its placeholder
height. Heights otherwise retain the existing lazy virtualization behavior.

The scroller is either the independent `.scrollable` node or the document's
scrollingElement. Only the list crossing the document reading edge owns a
correction for that scroller. Independent panes remain independent. Existing
insertion/pending-item and split-return anchor code still runs; the final pixel
correction removes the remaining delta rather than adding a second fixed shift.

Wheel/touch/pointer/keyboard input cancels the correction. New route/layout
identity cancels it too. Dropdown scroll locks, hidden documents and body media
locks skip correction. A focused descendant removed by hiding moves focus to a
surviving article without scrolling, or the list node; filtering is not delayed.
There are no perpetual rAF loops, MutationObservers, global DOM scans or forced
component remounts. If all nearby anchors disappear, only the old scroll offset
can be preserved; this is not a guarantee about the semantic reading row.

## Reproducible validation

Automated tests are in `filter_reconciliation/__tests__` and the existing P2,
Mix, notification and split suites. They use the real root reducer, importer,
P2 actions and selector, with controlled transport. Actual mounted StatusLists
cover instance identity, hidden restoration, featured/gap/bigint handling and
teardown. Scheduler cases cover 1000/2500 candidates, priority/fairness, 2000-entry
retention without churn, in-flight edits/generations, failed/unavailable/429,
visible revisit, local FilterModal attachment, expiry revival and repeated routes.

The Chromium fixture under `spec/browser/filter_reconciliation/` uses production
StatusList, ScrollableList, virtual articles, Redux root/P2/scheduler and selector.
**Only the transport and status body content/height are fixtures.** It is not a
Rails login/full-media/application E2E. Two independent list panes exercise the
same geometry path as split panes; existing real split-controller Jest suites
cover their Redux/layout identity and return anchors.

```sh
node node_modules/jest/bin/jest.js --runInBand --silent
NODE_OPTIONS=--openssl-legacy-provider node node_modules/webpack/bin/webpack.js \
  --config spec/browser/filter_reconciliation/webpack.config.js
python3 spec/browser/filter_reconciliation/run.py
python3 spec/browser/filter_reconciliation/run.py --without-anchors
python3 spec/browser/filter_reconciliation/profile.py
python3 spec/browser/filter_reconciliation/counters.py
FILTER_SCHEDULER_PROFILE=1 node node_modules/jest/bin/jest.js --runInBand \
  app/javascript/mastodon/filter_reconciliation/__tests__/scheduler-test.js \
  --testNamePattern='records bounded scheduler CPU'
```

Python Playwright and a local Chromium executable are required; they are not new
production dependencies. The runner serves only the local fixture. Native
browser scroll anchoring is disabled in the fixture so the comparison measures
this implementation. The `--without-anchors` variant disables its correction as
a control. Results, commands, actual build/test totals and measurement limits are
recorded in the Draft PR. Local mocked-network timings are not a production SLA.


## Executed results (2026-10-16)

Base is `ba6808b0f648dfb33313910fbb0da23477211c25` (merged P2 #466).

- New P3 Jest: **3 suites / 40 tests passed**.
- Entire Jest: **223 suites passed / 11 failed**, **1927 tests passed / 13 failed**,
  **13 snapshots passed**, 81.991s. All 11 failing suites were rerun with the
  modified existing JS files temporarily restored to this base; all 13 failing
  test fullNames matched. The implementation was restored afterwards.
- Existing failures: submit-compose, portable_composer,
  compose_form_container-target, emoji, mix-nav, custom_emoji_titles,
  translation-bar-visibility; the collected status_list_split_mock helper and
  three streaming Node-test files collected by Jest. This is not an all-green
  suite. No additional failing suite/case appeared.
- ESLint on changed application/test JS and separately the four ignored-by-default
  browser-fixture JS files: **0 errors / 0 warnings**; diff check passed.
- Final development webpack: **56.919s**, production webpack: **98.044s**, both
  exit 0. Existing Sass/Browserslist/asset-size warnings remain. Commands used
  NODE_ENV/RAILS_ENV for the respective mode, NODE_OPTIONS=--openssl-legacy-provider
  and `node node_modules/webpack/bin/webpack.js --config config/webpack/<mode>.js`.

Chromium geometry (120 owned IDs, fixed-height status bodies, native anchoring
turned off; ordinary lists and Mix use the same production components):

| Layout | Ordinary hide delta | Mix hide delta | Restoration delta |
| --- | ---: | ---: | ---: |
| Document / one column | 0px | 0px | 0px |
| Two independent columns | 0px | 0px | 0px |
| Two stacked independent panes | 0px | 0px | 0px |

The anchor-disabled control moved 480px in five configurations and 0px in the
ordinary-document case (the retained virtual height absorbed that change).
Warn/hide display changes, anchor disappearance, manual input cancellation,
changing document/column binding, Composer DOM/draft identity and final cleanup
are also asserted by the runner. Layout-switch and warn assertions allow <=2px;
they are not published as additional exact-zero measurements. Full Rails,
real-media rendering, real mobile Safari and multi-day browser soak are untested.

Browser load profile: two duplicate columns, fixed-size content, mock transport
with 10ms reply delay. Initial mounting and explicit GC occur before measurement.
The before column is the initial P3 prototype before shared selector subsets and
batched IO priority updates, **not** the upstream P2 application.

| Owned IDs | POSTs / max batch / concurrency | Completion before -> after | CDP task CPU before -> after | First POST after |
| --- | --- | ---: | ---: | ---: |
| 1000 | 10 / 100 / 1 | 3394.1 -> 1860.9ms | 3446.6 -> 1909.6ms | 387.6ms |
| 2000 | 20 / 100 / 1 | 12391.3 -> 5082.0ms | 12434.6 -> 5126.2ms | 695.6ms |

Observed minimum POST spacing after optimization was 137.3ms / 186.5ms; the 80ms
scheduler floor is not a promise of wall-clock completion time. Browser task CPU
and elapsed duration use separate CDP/evaluation measurement brackets. Large
mounted/virtualized lists still cost substantial rendering time; there is no
production performance guarantee.

| IDs | Whole-fixture used JS heap before | After reconciliation | After unmount + GC |
| --- | ---: | ---: | ---: |
| 1000 | 46.08 MiB | 53.76 MiB | 52.39 MiB |
| 2000 | 77.37 MiB | 96.22 MiB | 92.29 MiB |

The browser heap includes Redux/statuses, React, selector/JIT/runtime caches and
fixture state. It did **not** return to its initial size; this is not evidence of
full memory reclamation or a multi-day leak test. Exact scheduler counters after
unmount were surfaces=retained=attempts=inflight=active=timers=0. Five 2000-ID
route cycles in the real-Redux Jest test also returned those counters to zero
without an eviction/requery loop (100 total POSTs across those cycles).


## First-review followup (#470)

The latest fetched `fedibird` base is
`3b3d0681416dbfda72a9ea45175a8c4c899e816c` (upstream #471), merged into this branch without conflicts.
The full Jest/build and six scroll configurations below were rerun after this
base synchronization. The performance comparisons were captured on the review
fix before that unrelated hashtag base update, using the same fixture.
The two first-review findings are addressed in the same Draft PR; Rails API,
timeline ID arrays, Composer and translation reducers are unchanged.

- P3-focused Jest: **4 suites / 56 tests passed** (the original 40 plus 16).
  Reverting the four affected production files to reviewed HEAD `7c1a292e7`
  made 12 new assertions fail (44 passed); all files were restored afterwards.
  Added checks cover 600 ordinary import actions without snapshots, pre-subscriber
  ordering, targeted original/poll edits, no-op/stale responses, <=18 rect reads
  for 2000 rows, multiple changes within two correction frames, all nine
  notification types' live hide/warn/actions and self-post exclusion with a
  different notification actor. Notification/arrival reducer identity is retained.
- Entire Jest: **224 suites passed / 11 failed**, **1996 tests passed / 13 failed**. All 11 failed suite paths and 13 failed assertion fullNames match the previously reproduced pre-#471 base failures; no additional failure.
- Changed application/test and fixture JS ESLint: **0 errors / 0 warnings**; diff check passed.
- development-build: exit 0, 36.005s wall time (including process startup). Existing warnings remain.
- production-build: exit 0, 73.573s wall time (including process startup). Existing warnings remain.

The six Chromium geometry configurations were rerun: hide/restoration/manual
scroll deltas were all **0px**; warn/layout-switch assertions stayed <=2px.
The same fixed-body/mock-transport limits as the initial run apply.

`counters.py` issues 180 real normalized import actions over 60 animation frames
(counter-only STATUS_IMPORT, batch import plus an unowned arrival, and poll vote
counts). Two duplicate columns retain 1000/2000 IDs. It counts article rect reads,
CDP Layout duration/count, traced synchronous Layout events with a JS stack, and
PerformanceObserver long tasks. Initial mounting/poll setup are excluded.
Both sides use the same updated counter-rendering fixture; before is reviewed
HEAD `7c1a292e7`, after is this implementation. One run per size, no SLA claim.

| IDs | Article rect reads before -> after | JS-stack synchronous layouts | Total layout ms | Task CPU ms | Long tasks / max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1000 | 60240 -> 0 | 0 -> 0 | 103.3 -> 115.5 | 6810.0 -> 7521.2 | 60/144 -> 60/165 |
| 2000 | 120240 -> 0 | 1 -> 0 | 181.0 -> 196.8 | 14442.3 -> 14534.5 | 60/351 -> 60/317 |

The frame-paced workload usually reaches clean layout before the old snapshot;
rect-read counts are not counts of forced layout. A separate small trace control
with three dirty-style writes/readbacks produced three JS-stack Layout events,
confirming the classifier. The table reports observed synchronous events only;
it does not establish a general forced-layout reduction. Long tasks remain
substantial in this large mounted-list fixture; removing snapshots does not
remove the cost of notifying thousands of React/Redux row subscriptions.

The unchanged reconciliation profile (initial mount/GC excluded, 10ms mock API)
was also compared with reviewed HEAD using the same counter-rendering fixture:

| IDs | POSTs / max batch / concurrency | Completion ms before -> after | Task CPU ms | First POST ms |
| --- | --- | ---: | ---: | ---: |
| 1000 | 10 / 100 / 1 | 1976.7 -> 1884.8 | 2021.9 -> 1928.6 | 416.6 -> 403.2 |
| 2000 | 20 / 100 / 1 | 5174.1 -> 5243.4 | 5224.3 -> 5305.0 | 706.8 -> 688.5 |

The 2000-ID result remains about 5.2s in this single-run comparison. Scheduler
counters return to zero after unmount; this is still not a heap-leak/soak claim.
Search/detail adapters, full-media/Rails E2E, real mobile Safari, multi-day soak
and production-load validation remain outside this change. Draft/re-review only;
no pull request merge or deployment.
