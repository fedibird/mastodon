# Emoji reaction fallback policy (P1b-1b)

Issue: fedibird/mastodon#582. Design: `docs/emoji_reaction_capability_resolver.md` sections 3.3, 5.1.2, 6, 7, 8, 11. Canonical writes stay as in `docs/emoji_reaction_canonical_writes.md`. P1a shadow mode is unchanged.

This ships the user choice `allow` / `ask` / `deny` and the server gate that can refuse a **new** reaction when today's sender would enqueue a `Like` to the post's server, or when that send is classified `unknown`. The gate ships **off**. Activity types, Undo, fan-out audiences, the database schema, and the proposed `DeliveryPlan` are not changed.

## What is stored

`emoji_reaction_fallback_policy` is a user setting. `config/settings.yml` defaults it to `allow`.

| Stored value | Effective value | Reader `state` |
|---|---|---|
| no row | `allow` | `absent` |
| `nil` | `allow` | `nil` |
| `allow`, `ask`, or `deny` | that string | `present` |
| anything else (`true`, `1`, `yes`, `Allow`, `grandfathered`, …) | `allow` | `present`, `configured` is the raw value |

The raw row is not rewritten. A stored `allow` / `ask` / `deny` wins over the default. P1c grandfathering (`source: grandfathered`, default `ask` for new accounts) is not implemented.

`GET /api/v1/fedibird/preferences` publishes `user.emoji_reaction_fallback_policy` to the signed-in user (`read` or `read:preferences`). `PATCH` and `reset` reject the key with `unknown_key` and do not write it, including when the same body also updates one of the nine writable keys. `UserPreferences::Schema` marks the stored key `write_policy: :read_only`. `Writer` and `WriteContract` never read `write_policy`; the rejection is the key's absence from `WriteContract::KEYS`. Adding the key to that list would make it writable even while the definition says read-only.

InitialState `meta.emoji_reaction_fallback_policy` is the effective value. Logged-out responses omit it. The WebUI export is not imported yet (the picker is P2). An open page can hold a stale value; the write gate does not trust it.

## Safety form

The choice sits on the safety preferences form, next to `disable_reactions`. `disable_reactions` is unchanged: the controller still returns 403 `This action is not allowed` with no `error_code`, and the service does not grow a second check.

Wording names a Like sent **to the server that hosts the post**. It says that a reaction on a local post can still reach followers as a favourite, and it does not say that no Like is ever sent.

`ask` is not an option while `FallbackPolicy.picker_confirmation_available?` is false (it is false until P2). Submitting `ask`, a blank, or any other value raises and saves nothing in that request. A value that was already stored as `ask` (console, or a later flag) is shown with a warning and is not overwritten until the person picks `allow` or `deny`. The form also says whether enforcement is on, so a saved `deny` is not presented as already changing delivery while the flag is off.

## Enforcement flag

| Variable | Default | Meaning |
|---|---|---|
| `EMOJI_REACTION_FALLBACK_POLICY_ENFORCE` | unset (off) | Request the gate. Only the exact string `true` counts. |
| `EMOJI_REACTION_CANONICAL_WRITES` | unset (off) | Required prerequisite (P1b-1a). |
| `EMOJI_REACTION_IDEMPOTENT_RETRY` | unset (off) | Required prerequisite (P1b-1a). |

`FallbackPolicyConfig.effective?` is true only when all three are exactly `true`. If enforce is requested and either prerequisite is missing, the gate stays off and the process logs one warning:

`[emoji_reaction_fallback_policy] EMOJI_REACTION_FALLBACK_POLICY_ENFORCE=true but EMOJI_REACTION_CANONICAL_WRITES and EMOJI_REACTION_IDEMPOTENT_RETRY are not both true; enforcement is off`

The process does not refuse to boot. A partial gate would bind a boost to a different status id than the row, or would accept a confirmation and then deliver again on a repeat PUT. Off means the legacy write, including when the stored policy is `deny` or `ask`. No policy read, no node snapshot query, no Redis, and no change to the activity type.

Sidekiq does not read the flag. The request process decides and, for a remote author, serializes the activity before enqueue.

## Actual delivery, not the proposed plan

`EmojiReactionCapability::ActualDelivery` is the label the gate uses. `DeliveryPlan` stays the P1a proposal. The P1b-1c subflags (`delivery_plan_unknown_node`, `delivery_plan_unicode_only_custom`, `delivery_plan_refuse_unsupported`, undo symmetry, fan-out) are not implemented and are off.

The legacy remote choice, shared with `EmojiReactionService#create_notification`, is:

- no node: `Like` (`nil` is not the `FEATURES` default)
- a node whose `info` omits `emoji_reaction_type`: `EmojiReact` (the `FEATURES` default is `custom`), unless `software` is exactly `kmyblue`
- `emoji_reaction_type` `unicode` or `custom`: `EmojiReact`, unless `software` is exactly `kmyblue`
- anything else, including `none`: `Like`
- `kmyblue` is case-sensitive, matching `create_notification`. An admin `info_override` is ignored here, because `Node#features` reads `info` only

When the gate approved the insert, that activity type is the one enqueued. The node is not read again in `create_notification`, so the accepted decision and the job cannot disagree if the row changes mid-request. With the gate off, `create_notification` still calls `legacy_remote_type` on `account.node`.

`unknown` is the conservative label where the proposal and today's send disagree, or where today's inputs are not a known capability (section 11, Q3 and Q7):

| Case | Today's activity | Policy label | `allow` | `ask` | `deny` |
|---|---|---|---|---|---|
| Local author | fan-out worker, not one Like to the author | `native` (`local_fanout`) | 200, fan-out unchanged | 200 | 200 |
| Silenced author | nothing | `not_delivered` | 200, nothing sent | 200 | 200 |
| Not ActivityPub | nothing | `not_delivered` | 200, nothing sent | 200 | 200 |
| No node row (Q3) | `Like` | `unknown` | 200 `Like` | 409 | 403 `capability_unknown_denied` |
| Empty `info`, or type missing, nodeinfo present (Q3) | `EmojiReact` | `unknown` | 200 `EmojiReact` | 409 | 403 `capability_unknown_denied` |
| NodeInfo missing, stale `info` still says `custom` (Q3) | `EmojiReact` | `unknown` | 200 `EmojiReact` | 409 | 403 `capability_unknown_denied` |
| `software` exactly `kmyblue` | `Like` | `like_fallback` | 200 `Like` | 409 | 403 `fallback_denied` |
| Type `unicode`, custom emoji (Q7) | `EmojiReact` | `unknown` | 200 `EmojiReact` | 409 | 403 `capability_unknown_denied` |
| Type `unicode` or `custom`, unicode emoji, not kmyblue | `EmojiReact` | `native` | 200 | 200 | 200 |
| Type `none`, including birdsitelive `favourite: none` | `Like` | `like_fallback` | 200 `Like` | 409 | 403 `fallback_denied` |
| `info` says `none` but `info_override` says `custom` | `Like` (override is not what is sent) | `like_fallback` | 200 `Like` | 409 | 403 `fallback_denied` |

`unknown` + `allow` keeps today's activity (Q3/Q7 subflags stay off). `unknown` + `ask` confirms. `unknown` + `deny` refuses. A `Like` is never labeled `native`. A new `unsupported` 422, a `target_max` refusal, and a fan-out audience change are not enabled. birdsitelive still receives a `Like` when the policy is `allow`.

The label is about the post's server. A `deny` user reacting to a **local** post still fan-outs; followers on a fallback node can still see a favourite (Q21). The form says so.

A boost is decided on the original author (`WriteTarget`, which enforcement requires). The booster's node is not the policy target. The token binds that canonical status id, so a token from the boost URL redeems on the original and the reverse.

An existing `(account, canonical status, name)` row is returned before the gate. A later change to `deny` or `ask` does not 403/409 that PUT and does not enqueue again (idempotent retry is required whenever the gate is on). Removal is not gated. `UnEmojiReactionService` still chooses the Undo type from the current node, including the existing kmyblue/unicode disagreement. A remote custom emoji that is not already used on the status is still a 200 with no row (Q8), and the gate does not run.

If the reactor has no user record, a `like_fallback` or `unknown` write is `403 capability_unknown_denied` rather than an assumed `allow`. A database error is not rescued into a Like.

## Confirmation token

`ask` without a usable token does not insert, notify, or enqueue. The response is `409` with `error_code: fallback_confirmation_required` and `details`: `mechanism`, `effects`, `confirmation_token`, `expires_in` (300). `effects` is `["remote_favourite"]` when the activity would be `Like`, and `[]` when an unknown case would still send `EmojiReact`.

The client repeats the same `PUT` with `fallback_confirmation=<token>`. Rails reads that from the JSON body, the form body, or the query string. A header is ignored. Prefer the body: proxies log query strings. The parameter is on `filter_parameters`. The token is not written to the log by this code.

The token is `ActiveSupport::MessageVerifier` (SHA256, JSON), purpose `:emoji_reaction_fallback`, lifetime 5 minutes. It binds `user_id`, canonical `status_id`, emoji identity (unicode string as stored on `EmojiReaction#name`, or resolved `custom_emoji_id`), target domain, mechanism, activity type, effects, policy `ask`, a digest of the normalized snapshot plus that legacy send, and a `jti`. `stale` is not in the digest.

Redemption recomputes the decision:

| Recomputed decision | Result |
|---|---|
| `deny` | `403`. The token cannot override it. `fallback_denied` or `capability_unknown_denied`. |
| native, not delivered, or policy `allow` | The token is ignored and the write proceeds. |
| still `ask`, binding matches | Redis `SET key NX EX` (`emoji_reaction_fallback:v1:<jti>`, TTL 6 minutes). First caller proceeds. |
| still `ask`, binding does not match, expired, or already used | `409 fallback_confirmation_invalid` and a new token. The failed call does not insert. |

The key is consumed when the binding matches, **before** insert. A later validation error (the per-account cap, an unrecognized emoji) spends the token; the same token does not retry. A replay after a successful create finds the row and is the idempotent 200, which does not deliver again and does not consult the token. After that row is deleted, the same token is `409` and does not create another row. Two concurrent redemptions: one `SET NX` wins and may insert; the other is `409` and does not insert.

A Redis error on consume is `503` `fallback_confirmation_unavailable` with the existing temporary-error sentence, and nothing is inserted. Issuing a 409 does not touch Redis.

A client that reads the new token out of a 409 and sends it again has not proved a person confirmed. That is the same boundary as any OAuth client. `deny` is the setting that does not depend on the client stopping.

## Errors that this PR adds

Existing `error` strings stay. New fields are additive.

| Situation | HTTP | `error` | `error_code` |
|---|---|---|---|
| `disable_reactions` | 403 | `This action is not allowed` | none (unchanged) |
| policy `deny` and the send is `Like` | 403 | `This action is not allowed` | `fallback_denied` |
| policy `deny` or unreadable user, send is `unknown` | 403 | `This action is not allowed` | `capability_unknown_denied` |
| `ask`, no token | 409 | confirmation required | `fallback_confirmation_required` |
| `ask`, bad or used token | 409 | confirmation is no longer valid | `fallback_confirmation_invalid` |
| Redis unavailable while consuming | 503 | temporary problem sentence | `fallback_confirmation_unavailable` |
| not visible | 404 | `Record not found` | none |
| external target | 422 | unchanged guard, before the gate | none |
| cap / unrecognized emoji | 422 | unchanged validator | none |

No new route, no status inline capability, no migration, no `delivery_mechanism` column.

## Extra reads when the gate is on

Off: `effective?` reads three environment variables and returns. It does not call the gate.

On, new reaction, author is local, silenced, or not ActivityPub: no node snapshot query. The policy row is not read, because the label does not consult it.

On, new reaction, remote ActivityPub author: one `nodes` select (the snapshot columns, including `nodeinfo_missing`, not the `nodeinfo` document) and a read of the reactor's setting. No `UpdateNodeService` and no NodeInfo HTTP call. The association `account.node` is not loaded again on the way to `DeliveryWorker`, because the activity type is already chosen.

A repeat PUT of an existing row does not take that select.

## Rollout and rollback

Do not set the flag in production in this change. Suggested later order, after P1a shadow numbers and a staging check of write latency, the extra query, and the share of unknown nodes: staff, then a limited set of users, then everyone. Default stays `allow`. Flipping the default to `ask` is P1c and waits on the picker.

Rollback: unset `EMOJI_REACTION_FALLBACK_POLICY_ENFORCE` and restart web processes. The next request is the legacy write. Nothing is migrated. Jobs already queued are ordinary legacy payloads. A mixed fleet during a rolling restart can 403 on one process and 200 on another; restart the web processes together.

Turning the flag on does not change Undo, fan-out, or the activity type of a reaction the gate allows. It only refuses some new rows.
