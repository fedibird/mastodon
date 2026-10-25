# Emoji reaction Capability Resolver: shadow mode (P1a)

Issue: [fedibird/mastodon#574](https://github.com/fedibird/mastodon/issues/574), design: `docs/emoji_reaction_capability_resolver.md` (sections 4, 5.1, 5.2, 10, 11).

P1a adds a read-only resolver and compares what it would send with what the legacy code actually sends. **The legacy code stays the only actor.** Nothing here changes an `EmojiReact` / `Like` / `Undo` / fan-out, an acceptance or refusal, a REST response, a route, a serializer, a setting, or the database.

## What exists

| Piece | Where | Role |
|---|---|---|
| `EmojiReactionCapability::NodeSnapshot` | `app/lib/emoji_reaction_capability/node_snapshot.rb` | Pure normalization of the raw `nodes.info` / `info_override` / status values (design 5.1.1): admin override, then NodeInfo missing (stale `info` ignored), then `info`. Reads `favourite` as `accepts` / `rejects` (`'none'`) / `unknown` (`false`, absent). |
| `NodeSnapshotLoader` | same dir | One query; the `nodeinfo IS NULL OR nodeinfo->>'error' = 'missing'` condition is evaluated by PostgreSQL so the large `nodeinfo` / `instance_data` JSON is never read. |
| `Resolver`, `Mechanism`, `DeliveryPlan` | same dir | Pure decision core (no DB / Redis / network / clock): per-kind (`unicode`, `custom`) mechanism (`native`, `like_fallback`, `unknown`, `none`), availability, limits, estimated activity type. `fallback_policy` is an input only; P1a passes nothing and nothing enforces it. |
| `Shadow`, `ShadowComparator`, `ShadowRecorder` | same dir | Read-only observation hooks and aggregate counters. |
| `ShadowReport` and `rake emoji_reactions:shadow:report` | same dir, `lib/tasks/emoji_reaction_shadow.rake` | Summaries. |
| Hooks | `EmojiReactionService`, `UnEmojiReactionService`, `ActivityPub::CustomEmojiDistributionWorker` | One call each, **after** the legacy code has chosen and enqueued. |

The proposed plan encodes the design's end-state rules (native when the Node type covers the kind, `Like` for fallback and for unknown, nothing for `none` + `favourite: 'none'`, a gone Node, a silenced or non-ActivityPub author). It is a proposal. **Whether a remote server accepts, shows, or undoes either activity is not verified**; every `diff` below is an observation about this server's rules, never a claim about a remote server. In particular a custom emoji toward a `unicode`-only Node is labelled `unicode_only_custom` (design Q7, unverified) and "unknown is sent as `Like`" is design Q3, not a fact.

## Flag, and why an environment variable

| Variable | Default | Meaning |
|---|---|---|
| `EMOJI_REACTION_RESOLVER_SHADOW` | unset (off) | `true` enables shadow mode. Any other value is off. |
| `EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE` | `0.01` when enabled | Fraction of operations observed, clamped to 0..1. An unparsable value fails closed (`0.0`, observe nothing). |

Chosen over a `Setting` row and over a user setting because it matches `MODERATION_FOLLOW_GATE_SHADOW` and the `FOLLOW_IMPORT_*` flags, needs no stored data or migration, and is read from process memory: with the flag off a hook costs one `ENV` lookup (measured +1 allocation per operation, 0 queries, no Redis call). It is server-only. The design called for a site setting; P1a deliberately avoids persisted configuration, as the issue asks. Changing it needs a process restart (web and Sidekiq), which is also the rollback step.

## Turning it on, off, and rolling back

On (staging first): set both variables, restart web and Sidekiq processes. Start at the default rate. Read results with

```bash
bundle exec rake emoji_reactions:shadow:report HOURS=24
```

Off: unset `EMOJI_REACTION_RESOLVER_SHADOW` and restart. There is no persisted state to undo. Counters expire after 8 days; `rake emoji_reactions:shadow:reset` deletes them at once.

Roll back (turn it off) if any of these is seen while it is on:

- p95 of `POST/DELETE /api/v1/statuses/:id/emoji_reactions/:id` or of `CustomEmojiDistributionWorker` rises by more than a few percent versus the flag-off baseline;
- Redis memory or command rate attributable to `emoji_reaction_shadow:v1:*` keys grows beyond the few kilobytes per hour expected (fields are drawn from a closed vocabulary, see below);
- the `err|op=...` counters (`report` prints them) are more than a small share of observations, or the `[EmojiReactionCapability::Shadow] ... observation failed` warning appears continuously;
- any change in delivered activities, REST responses or job counts is suspected. None is expected: the specs pin identical payloads, recipients and jobs with the flag on and off.

## What is recorded, and privacy

One Redis hash per UTC hour, `emoji_reaction_shadow:v1:YYYYMMDDHH`, 8 day TTL, written with `HINCRBY` in one pipeline per sampled operation. Field kinds:

- `cmp|op|kind|family|node|legacy|proposed|basis|result`: one comparison. `op` is `create`, `undo`, `fanout_create`, `fanout_delete`. `legacy` and `proposed` are `EmojiReact`, `Like` or `none`. `result` is `match` or `diff`.
- `snap|src|node|family|reach|stale|override|stale_ignored`: one Node snapshot read (author or sampled receiver).
- `err|op`: a swallowed shadow failure.

Every value is checked against a closed list and replaced by `other` otherwise (`ShadowRecorder`). `family` is one of `mastodon fedibird pleroma akkoma gotosocial pixelfed friendica birdsitelive kmyblue misskey other unknown none`. No account id, status id, full domain, text, or emoji name is written to a counter, metric tag, or log line (a spec asserts this). The only log line is a rate-limited warning (at most one per error class per minute per process) containing the operation name and the exception class, never the message.

## What is compared

| Op | Legacy value (what actually happened) | Proposed value |
|---|---|---|
| `create` | the `type` `EmojiReactionService` just enqueued, or none for a silenced or non-ActivityPub author | `DeliveryPlan.for_status` for the canonical status (`status.proper`) author |
| `undo` | the type `UnEmojiReactionService` just enqueued. Its rule is separate from create and is not rewritten | the same plan as create (symmetric) |
| `fanout_create` / `fanout_delete` | per sampled receiver, the type the worker's own SQL predicates give (`info->>'emoji_reaction_type'`; NULL gives nothing; a receiver with no Node row gives nothing) | `DeliveryPlan.for_node` per receiver |

Canonical status: the author is `emoji_reaction.status.proper.account`, so a reaction made through a boost wrapper is judged against the original author's Node, as the legacy `create_notification` does (spec). The existing boost and idempotency bugs (design F15, F16) are neither fixed nor measured here; that is P1b.

Fan-out receivers are the **reactor's** delivery followers plus remote mentioned accounts of the status (`@account` in the worker is the reaction's account), not the status author's followers. Shadow samples at most `FANOUT_RECEIVER_SAMPLE` (50) receivers: remote accounts only, filtered **before** the `LIMIT` so local followers cannot exhaust the sample, with the budget split between the follower and mention branches (`ceil(N/2)` and the rest; unused quota of one branch goes to the other), then one join to `nodes`. It never evaluates the worker's `UNION`, sends nothing, and discovers no extra recipients for delivery.

**How to read the `fanout_*` numbers.** They are a bounded, non-random sample of *candidate receiver accounts*, and the legacy side is the worker's SQL predicates re-evaluated per sampled account, not a capture of the inboxes that were actually enqueued (no inbox de-duplication, no `DeliveryFailureTracker` filtering). Do not read the match rate or the Node distribution as a ratio of the real delivery population. Before any P1b change to fan-out delivery, add a separate check of the real delivered set (see Known observations).

**How to read `undo`.** A unicode Undo toward a remote ActivityPub author with no `nodes` row raises in legacy before the hook, so it is absent from the `undo` population; per-software Undo match rates can look better than they are. The report prints this note.

Counts of the viewer's existing rows are **not** read (design 5.2 requires them only where used). The resolver accepts `Counts`, and with no `delivery_mechanism` column `Counts.legacy(total)` marks every row unknown so no target limit and no refusal is ever asserted from it.

## Cost (measured)

`script/emoji_reaction_shadow_benchmark.rb`, test database, single process, 300 operations per mode, Node row with a 20 KB `nodeinfo`, Sidekiq fake, rolled-back transaction. Raw output is in the PR.

| Operation | OFF vs code without the hooks | ON, default rate | ON, rate 1.0 |
|---|---|---|---|
| `EmojiReactionService#call` (remote author) | +0 SQL, +1 allocation | +0.01 SQL/op | +1 SQL (narrow Node read), +390 allocations, about +0.5 ms p50 |
| `UnEmojiReactionService#call` | +0 SQL, +1 allocation | +0.01 SQL/op | +1 SQL, +400 allocations, about +1 ms p50 |
| `CustomEmojiDistributionWorker#perform`, any follower count | +0 SQL, +1 allocation | +0.0 to 0.2 SQL/op | +3 SQL (reactor follower branch, mention branch, node join), 3 to 200 receivers alike; +1.4k allocations at 3 receivers, +6k at 50 or more (50 receiver cap) |

The added queries do not grow with the number of statuses, receivers, or domains (specs: 7 versus 37 receivers add the same 3 queries; a single create adds exactly one). The Node read selects `id, domain, info, info_override, status, last_fetched_at` and the database-evaluated missing flag, never `nodeinfo` or `instance_data`. These are laboratory numbers on an empty database; they are not production p95 and should be re-measured on staging with production-shaped data before any rate above the default.

## Known observations (not fixed here)

- `UnEmojiReactionService` calls `status.account.node.features` without a nil check for a unicode emoji; a remote ActivityPub author with no `nodes` row raises `NoMethodError` today (pinned by a characterization spec). The exception happens before the shadow hook, so that case is not observed.
- The legacy fan-out sends `Like` for a unicode emoji to `custom`-type Nodes, while a create toward a remote author sends `EmojiReact` to the same Node; both are shown as `fanout_*` and `undo` diffs.
- `nodeinfo_missing` for a Node whose `nodeinfo` is present without an `error` key is SQL NULL in the raw expression; the loader wraps it in `COALESCE(..., false)`.

## Not done in P1a

No `delivery_mechanism` column, `fallback_policy` setting or enforcement, API route, serializer field, WebUI, Streaming, Settings Service, migration, schema change, rewrite of any Node `info`, or P1b-2 aggregation. No wire-change sub-flag (`delivery_plan_*`) exists, so none can be on.
