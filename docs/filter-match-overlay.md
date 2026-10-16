# Filter definition generations and match overlay (P2)

P2 connects complete filter snapshots, user-stream invalidation, the P1 match API and `makeGetStatus`. It never gathers timeline IDs, refreshes timelines, imports match results as statuses, manipulates scroll, or schedules batches. Those are P3 responsibilities. The API contract remains in `filter-matches-api.md`.

## Authoritative definitions and generations

All adopted `fetchFilters()` responses dispatch `FILTERS_FETCH_SUCCESS`. The existing per-store latest-request guard discards older GET successes and failures. Embedded Rails saves already await a post-mutation `fetchFilters()` in `submitFilterSettings`; passive iframe loads use the same action.

After a successful local `createFilterStatus`, the action immediately fetches complete definitions alongside the existing forced status refresh. The target-rule change advances the generation and invalidates confirmed nonmatches even for an already known filter, without waiting for `filters_changed`. Either GET response order converges through the legacy FilterResult until explicit reconciliation confirms the new generation. Success callbacks still report the committed attachment; a definition GET failure dispatches `FILTERS_FETCH_FAIL` without reporting the attachment as failed. It retains the previous generation until a later successful full refresh; no automatic retry or match POST is added.

The first complete snapshot establishes a baseline at generation 0. Only complete GET successes feed the canonical rule comparison. Filter order, keyword order, target order and numeric-versus-string IDs do not matter. Bigint strings are never converted to Number. Keyword ID/text/whole_word, target status IDs and nonempty filter additions/removals change the generation. A target-rule row ID replacement with the same target does not. Empty-condition filters are omitted from the comparison, so creating/deleting them is display-only. Deleting a nonempty filter advances the generation as a conservative rule change, while `state.filters` also makes it immediately inapplicable.

Title, action, contexts and ordinary expiration changes are applied by the existing filters reducer/selector without advancing generation. There is one expiry exception: reactivating a rule-bearing filter whose previous absolute deadline has passed advances the generation and invalidates old confirmations, including empty results computed while it was expired. The accepted GET carries receivedAt; the reducer compares old/new deadlines at that timestamp, so natural expiry between GETs is detected without polling. Future-to-future, expired-to-expired and empty-condition changes do not advance generation. Rules and reactivation in the same snapshot advance it only once. Reducers do not read the wall clock themselves. The generation and sticky `needsReconcile` signal indicate that matching rules have changed since baseline; they are not a claim that every timeline ID is known or reconciled. P3 can track which generation it has scheduled without P2 scanning the UI.

Before baseline, `FILTERS_IMPORT` retains its existing ability to hydrate simplified FilterResults. After baseline, the root reducer suppresses these unversioned imports, including IDs absent from the authoritative snapshot. They cannot revert current titles/actions/contexts, erase rules or resurrect deleted filters. Explicit `FILTERS_CREATE_SUCCESS` still adds a newly created filter for the existing modal; it is not a diff snapshot. Subsequent complete GET/stream notifications establish its rule generation.

The real importFetchedStatuses path collects filter IDs from REST/streaming results, including nested statuses and already normalized IDs. After baseline, an unknown ID is a hint for complete GET revalidation, never permission to promote partial metadata. This works without a connected user stream and shares the existing refresh coalescer/latest-request guard. A bounded 2000-ID hint/negative cache suppresses repeat attempts for 60 seconds, including deleted/absent IDs and failed requests. Distinct-ID storms trigger at most once per five seconds/store, with one trailing timer; the IDs still unknown are rechecked before triggering. Timers run only because payloads arrived, not on TTL expiry. With no new hints there is no polling or infinite retry. A newer full snapshot can make a queued hint obsolete.

Until the complete GET succeeds, unknown metadata is not applied to display. This necessary validation delay avoids resurrecting deleted IDs or trusting stale action/context. A failed revalidation keeps the provisional display; a fresh hint after the suppression interval, a user-stream event or reopening settings can recover it. A new hide filter becomes effective after authoritative revalidation even when the user stream is stopped.

## Stream updates and recovery

Rails publishes `filters_changed` to the existing `timeline:<account>` channel as well as the system channel. `streamFrom` already forwards non-status events on the `user` subscription; the system listener separately invalidates Node's filter cache. No server-stream changes are needed.

Only the WebUI `user` channel handles the event and refreshes definitions on connect/reconnect. Public/list/hashtag/other timeline subscriptions do not issue filter GETs. A WeakMap keyed by store dispatch holds at most one 250 ms timer and one stream-triggered in-flight GET, with one dirty trailing refresh. Bursts merge, and a persistent event stream cannot create parallel GETs through this scheduler. Failure does not retry without another event. Direct post-save/passive GETs remain immediate and retain latest-request protection against older stream GETs.

When streaming is absent or notifications were missed, opening/reloading the embedded settings screen fetches definitions; a later user-stream reconnect also refreshes them. There is no new polling, cross-tab bus or global focus observer. P2 does not automatically discover or reconcile posts after that refresh.

## Public action interface

```js
import { fetchFilters } from 'mastodon/actions/filters';
import { reconcileFilterMatches, clearFilterMatches } from 'mastodon/actions/filter_matches';

await dispatch(fetchFilters()); // establish complete baseline if not loaded yet
await dispatch(reconcileFilterMatches(['123', '9007199254740993']));
dispatch(clearFilterMatches(['123'])); // optional release; no argument clears all
```

The caller must provide an array of 0–100 positive signed-bigint decimal strings, before deduplication. Numbers and noncanonical IDs are rejected. Empty input is a no-op; nonempty input before baseline rejects rather than racing an unknown initial rule set. P2 sends exactly those IDs, normalized in first-occurrence order, to `POST /api/v1/fedibird/filters/matches`. It does not split oversized inputs. Invalid caller input rejects the action promise. HTTP/network/response-contract failures set a failed entry and resolve without an automatic retry; the caller can inspect state and retry explicitly.

An accepted response must partition all requested IDs exactly once between `matches` and `unavailable`; foreign IDs, omissions, overlapping/duplicate partitions, non-array matches and non-string/non-bigint filter IDs fail the whole response. Valid empty matches are confirmed nonmatches. `unavailable` never becomes an empty array.

## State, races and selector policy

`state.filterMatches` contains baseline, generation, monotonically increasing request serial, canonical rules, `needsReconcile`, and an insertion-ordered bounded map of entries. Entries contain only phase, generation/request identity and filter IDs/result generation. There are no status bodies, translations, media snapshots or timeline IDs here. Missing entries are unevaluated; phases are pending, ready, unavailable, failed and unevaluated (after a content change).

Each explicit request stamps the current generation and a new serial onto each ID. Results/failures are accepted independently per ID only if both identities remain current. Thus a late overlapping request can still settle an untouched ID but cannot roll back a newer request's ID. Old-generation results are ignored. Clearing, eviction, deletion or content invalidation also prevent an outstanding response from restoring the removed result. Serial identity is not reset by cleanup.

`makeGetStatus` uses the requested wrapper's current-generation confirmed filter IDs before legacy `status.filtered`. It never substitutes an original's overlay for a wrapper's overlay. The existing `state.filters`, viewer identity and `toServerSideType` still compute hide/warn/titles/context/expiry/own-post exclusion. Quotes keep their existing rendering and matching semantics; Mix supplies its existing source context. Notification arrival-time drop/sound/browser-alert behavior is unchanged.

Fallback is deliberately conservative and backward compatible: before confirmation, after generation/content invalidation, after unavailable, or on failure without a current confirmed result, use the legacy FilterResults and current filter definitions. These may temporarily retain an old hide; they are **not** recorded as a confirmed result for the new generation. A current-generation confirmed result (including `[]`) stays usable during a new pending request or a network failure if the content has not changed. Unavailable discards that confirmation. Only an explicit successful match response can establish a new confirmed empty match. This avoids exposing previously hidden content merely because it has not been checked or a request failed. P3 must schedule the pending IDs to converge these provisional displays.

Display-only changes act immediately on IDs already known to match. Expired-to-active revival of a rule-bearing filter is a matching-epoch change, although the keyword/target definitions are identical: the P1 API omitted that filter while expired. P3 must treat the advanced generation exactly like a keyword change and schedule relevant IDs. Old ready=[] is no longer authoritative, and an explicit reconciliation confirms the restored match. P2 still supplies no automatic wall-clock expiry polling beyond the existing selector's time check and does not collect IDs or issue match POSTs on its own.

## Status lifecycle and memory

The root reducer compares the old and new status/poll subtrees after the actual `STATUS_IMPORT`, `STATUSES_IMPORT` and `POLLS_IMPORT` reducers run. It inspects only tracked overlay IDs (maximum 2000) and each one's original, not all statuses or timelines. Unchanged subtrees take a fast path. Incoming status/poll/lifecycle IDs first select affected entries and their tracked originals; only these receive full content comparisons. Identifying wrappers still scans the bounded overlay for dependency IDs (no full status/TL scan or new reverse-index lifetime). It invalidates results and request identity on body/CW/edit stamp, ALT/media identity, poll option titles, references/status_reference_ids, quote/reblog identity, canonical URL/URI, account or visibility/lifecycle changes. Counter/reaction updates, poll vote counters and incoming stale `filtered` metadata do not invalidate a confirmed result. Poll translations and media translations are not matching sources.

An original's import or poll change invalidates tracked wrappers. Changes in a referenced/quoted post's body do not cause recursive traversal or broaden the server's existing semantics. Deleted/expired IDs and tracked wrappers are removed on the existing lifecycle actions, even where the statuses reducer retains the expired record. Late responses cannot recreate those entries. At most 2000 IDs are retained; the oldest requested ID is evicted on overflow. The caller may release entries explicitly. There is no persistent overlay storage or unbounded retry/history list.

Reconciliation actions leave every other Redux subtree at the identical reference, including statuses, primary/portable composers, drafts/edit state/CW/media, translation/bilingual state, reactions, timeline/Mix IDs and Live/History data. Selector output can naturally hide/show rows; P2 adds no scroll adjustment or remount mechanism.

## Validation and P3 work

The mounted-surface scheduler and scroll layer built on this interface are documented in [filter-reconciliation.md](filter-reconciliation.md), including its supported surfaces, explicit adapter gaps, capacity and validation limits. P2 remains the explicit-ID transport/overlay layer described here.

The integration suite uses the real root reducer, importer/normalizer and `makeGetStatus`, with a mocked transport. It covers definition differences and partial imports, reversed GET responses, iframe/stream races, event bursts/reconnects, API validation/error states, generation/per-ID request races, wrapper/original/quote/context differences, content/poll/ALT changes, state reference preservation, deletion/expiry, eviction and cleanup. The former source-text assertion prohibiting any WebUI `filters_changed` handler is superseded by these behavioral tests; SQL/streaming filtering checks remain.

P3 must collect relevant IDs, retain source contexts, prioritize visible statuses, bound concurrency and batches, revisit stale/failed/unavailable IDs appropriately, and perform scroll anchoring when row visibility changes. It should consume the generation (including expired-filter revival) and entry phases, call the exported actions and release unneeded IDs; it must not rewrite status bodies or restore cleared results from old requests. P2 intentionally adds no developer UI or production global for manually calling the action.

Measurements and executed versus unexecuted checks are recorded in the PR. Definition diff cost depends on the number/size of rules (sorting per filter plus equality comparison) and occurs only on adopted full GETs. Status lifecycle work is bounded by the tracked overlay size; result storage also scales with the returned filter-ID count. Local test timings are not production performance guarantees. Browser rendering/scroll behavior under mass reconciliation remains a P3 validation task.

PR #466 review validation also profiles a single incoming import with 2000 retained entries. The integration test can print 100-sample lifecycle and complete-importer timings with FILTER_OVERLAY_PROFILE=1; the PR reports paired before/after results. Unknown-ID handling tests cover offline user stream, repeated deleted IDs, response reversal, failures, normalized IDs and a 2500-ID hint storm.

Review measurement (same fixture, 100 samples, local Jest/jsdom; no concurrent build):

| Operation with 2000 retained IDs | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| Lifecycle validation of one changed body | 2.256 / 5.308 ms | 0.738 / 2.596 ms |
| Complete importer for one counter-refresh payload | 2.811 / 4.443 ms | 1.166 / 2.185 ms |

The fixture uses ordinary posts with ready empty-match entries. These timings exclude React rendering/network latency and are not a production SLA. A bounded dependency scan remains; if all tracked wrappers share a changed original, all are legitimately affected. A global reverse index or P3 timeline/visible-range scheduler is not introduced here. Reactivation conservatively invalidates the whole matching generation, trading some extra P3 work for rejection of stale empty results.
