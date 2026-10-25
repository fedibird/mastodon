# Emoji reaction Capability Resolver: P0 design and inventory

Issue: [fedibird/mastodon#572](https://github.com/fedibird/mastodon/issues/572)

Status: design only. This document is the whole P0 deliverable. It adds no route, column, setting, serializer field, feature flag, or WebUI behavior, and it does not migrate or deploy anything. Every behavior described in section 1 is read from the `fedibird` branch at commit `86218c57d9`. Everything from section 2 on is a proposal. Where the code was not enough to decide, the question is listed in section 12 and not guessed.

Terms: "reactor" is the account that adds a reaction. "Author" is the account that owns the status, always `status.proper.account`. "Target Node" is the `Node` row for the author's domain. "Like fallback" is delivering a reaction as an ActivityPub `Like` activity that carries `content` (and a `tag` for a custom emoji) instead of an `EmojiReact`.

## 0. Summary of what the inventory found

The decision "how is this reaction delivered, and may it be?" exists today in six places that do not agree with each other. These are the facts the design has to start from.

| # | Finding | Where |
|---|---|---|
| F1 | Create decides `EmojiReact` vs `Like` from `Node#features(:emoji_reaction_type)` plus a `kmyblue` special case. Undo decides from a different rule (`EmojiReact` only for a unicode emoji on a `unicode` Node) and has no `kmyblue` case. A reaction created as `EmojiReact` on a `custom` Node is undone with `Undo(Like)`. | `EmojiReactionService#create_notification`, `UnEmojiReactionService#create_notification` |
| F2 | Like fallback is not a policy. It is the `else` branch. A remote author whose Node says `emoji_reaction_type: none` (for example `birdsitelive`) still receives a `Like` carrying the emoji. A Node row that does not exist at all also gets a `Like`. | `EmojiReactionService#create_notification` |
| F3 | "Unknown" is treated as native. `Node#features` returns the `FEATURES` default (`'custom'`) whenever `info` has no value. `process_features` is skipped when NodeInfo is missing, so a Node with no NodeInfo reads as native `custom`. | `Node#features`, `UpdateNodeService#proccess_info` |
| F4 | The local-author fan-out filters with SQL (`info->>'emoji_reaction_type' != 'none'`, `= 'custom'`, `= 'unicode'`). A Node whose `info` has no key evaluates to SQL NULL and is excluded. The same Node reads as `'custom'` through `Node#features`. The two code paths disagree about the same Node. | `ActivityPub::CustomEmojiDistributionWorker#inboxes` and neighbors |
| F5 | `Node::FEATURES[:emoji_reaction_max]` is `[MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max` evaluated once at class load. It is the local site cap, not a remote value, and it goes stale until the process restarts. `REST::NodeSerializer` falls back to `1` when it is missing. The write path never reads `emoji_reaction_max`. | `app/models/node.rb`, `app/serializers/rest/node_serializer.rb` |
| F6 | `REST::NodeSerializer` has no controller and no route. It is defined but unused. | `rg NodeSerializer app` |
| F7 | `disable_reactions` is enforced only in controllers (`Statuses::EmojiReactionsController#update`, `FavouritesController#create`, `ReblogsController#create`). `EmojiReactionService` does not check it. `EmojiReactionService` includes `Authorization` but never calls `authorize`; the only policy check is `authorize @status, :show?` in the controller. There is no `emoji_react?` policy method. | controllers above, `StatusPolicy` |
| F8 | The local per-account cap is a validator that counts rows and then inserts, with no lock. Two concurrent requests can both pass. The unique index is `(account_id, status_id, name)`, so it only prevents the same name twice. | `EmojiReactionValidator`, `db/schema.rb` |
| F9 | `EmojiReactionValidator::LIMIT` (20) is not a write cap. It limits the number of distinct names kept in the grouped cache (`Status#generate_grouped_emoji_reactions`). A 21st distinct reaction is stored and not shown. | `app/models/status.rb` |
| F10 | `EmojiReactionService#call` returns `nil` without error when a remote custom emoji is not already on the status. The controller then answers `200` with an unchanged status. | `EmojiReactionService#call` |
| F11 | The WebUI computes "limit reached" from the site cap and the viewer's count taken from the grouped cache (`me` flags), ignoring the author's Node. It cannot know about unsupported servers. | `containers/status_container.js`, `features/status/index.js`, `initial_state.js` |
| F12 | `POST /api/v1/statuses/:status_id/emoji_unreaction` has no emoji segment, so `params[:id]` is `nil`. `UnEmojiReactionService` then parses no shortcode and removes all of the viewer's reactions on that status, even though the controller passes `shortcode_only: true`. This is by inspection only, not exercised. | `config/routes.rb`, `UnEmojiReactionService#call` |
| F13 | For a silenced remote author, the reaction is stored locally and nothing is delivered (`return if status.account.silenced?`). Local acceptance does not imply federation. | `EmojiReactionService#create_notification` |

## 1. Inventory

### 1.1 Create entry points

| Entry | Path | Notes |
|---|---|---|
| REST | `PUT /api/v1/statuses/:status_id/emoji_reactions/:id`, `POST /api/v1/statuses/:status_id/react/:id` (glitch-soc alias) | `app/controllers/api/v1/statuses/emoji_reactions_controller.rb#update`. Scope `write` or `write:favourites`. `require_user!`, `set_status` runs `authorize @status, :show?` and maps `NotPermittedError` to 404. `current_user.setting_disable_reactions` raises `NotPermittedError` (403). The `:id` is `shortcode` or `shortcode@domain`. The status loaded is the requested one; for a reblog wrapper `EmojiReaction` rewrites `status` to `status.reblog` in `before_validation`. |
| ActivityPub inbound | `Like` and `EmojiReact` both dispatch to `ActivityPub::Activity::Like` (`app/lib/activitypub/activity.rb`) | `Like#perform`: no `content` (or `_misskey_reaction == '⭐'`) becomes a `Favourite`; otherwise `process_reaction` creates an `EmojiReaction` with `uri` set. Only blocks are checked (author blocking the sender, sender blocking the author, author's domain block). No viewer setting, no per-status override, no `disable_reactions`, no cap other than the validator's remote cap of 20. |
| Service | `app/services/emoji_reaction_service.rb` | The only local writer. Guards: `ExternalBridge::Guards.reject_target!`, the foreign-custom-emoji no-op (F10). Creates with a find-first, rescue `RecordNotUnique` pattern, then notifies (local author), delivers (remote ActivityPub author) or distributes (local author), bumps potential friendship, records a moderation event. |

There are no other writers of `EmojiReaction` rows in `app/` or `lib/` (`rg 'EmojiReaction\.(create|find_or)|emoji_reactions\.(create|destroy)' app lib`).

### 1.2 Delete entry points

| Entry | Path | Notes |
|---|---|---|
| REST | `DELETE /api/v1/statuses/:status_id/emoji_reactions/:id`, `POST .../unreact/:id`, `POST .../emoji_unreaction` | `#destroy` calls `UnEmojiReactionService` with `shortcode_only: true`. No `disable_reactions` check, so removal is already allowed when adding is not. The response passes `emoji_reactions_map: { id => false }` to skip a stale relationship read. For the route without an emoji see F12. |
| ActivityPub inbound | `ActivityPub::Activity::Undo` with `Like` or `EmojiReact` object, and `handle_reference` (`try_undo_react`, matched by `emoji_reactions.uri`) | `try_undo_like` is a deliberate `false`, so an `Undo` that references a `Like` by bare id works only for reactions, not for favourites. |
| Cascade | `Status` `has_many :emoji_reactions, dependent: :destroy`, DB `ON DELETE CASCADE`, `DeleteAccountService#purge_emoji_reactions!` | Uses `EmojiReactionCacheInvalidator.mark_for_emoji_reactions`; nothing is delivered. |
| Custom emoji disabled | `EmojiReaction.enabled` scope and `EmojiReactionCacheInvalidator.mark_for_custom_emoji_ids` | The row stays; the reaction is hidden from lists and counts. |

### 1.3 Dispatch and undo (federation)

| Case | Create | Undo |
|---|---|---|
| Local reactor, remote ActivityPub author | `EmojiReactionService#create_notification`: type `EmojiReact` if `node&.features(:emoji_reaction_type)` is `unicode` or `custom`, else `Like`; forced to `Like` if `node.software == 'kmyblue'`. One delivery to `status.account.inbox_url`. Skipped if the author is silenced. | `UnEmojiReactionService#create_notification`: `EmojiReact` only if `emoji_reaction.unicode?` and the Node type is `unicode`; otherwise `Like`. No kmyblue case. Does not skip silenced authors. See F1. |
| Local reactor, local author | `NotifyService` (`:emoji_reaction`), then `ActivityPub::CustomEmojiDistributionWorker` `create` | `CustomEmojiDistributionWorker` `delete`, called synchronously with `.new.perform` |
| Fan-out for a local author | Receivers: followers (delivery followers plus remote mentioned accounts) for follower-visible statuses, remote mentioned accounts for limited and direct, nobody for the rest. Unicode emoji: `Like` to Nodes of type `custom`, `EmojiReact` to Nodes of type `unicode`. Custom emoji: `Like` to every Node whose type is not `none`. Nodes with a NULL type get nothing (F4). Relay delivery is commented out. | same worker with the undo serializer |
| Remote reactor to local author | `Like#process_reaction`, notification only if the sender is not silenced and not excluded; optional forwarding (`forward_for_emoji_reaction`) and relay push for signed public activities | `Undo` handlers above |

The activity payload is `ActivityPub::EmojiReactionSerializer`. Its `type` is the `instance_options[:type]` (`Like` or `EmojiReact`), `content` is the unicode name or `:shortcode:`, and `tag` carries the custom emoji. The activity id is `<actor>#emoji_reactions/<row id>`.

### 1.4 Node capability inference

`UpdateNodeService` is the only writer of `Node#info`. The merge order inside `proccess_info` is:

1. `preprocess_info` (ensure `{}`).
2. When `node.node?` (NodeInfo present): `process_features` (inferred), `process_software_specific_override` (`birdsitelive` sets `emoji_reaction_type: none`, `emoji_reaction_max: 0`, `favourite/reply/reblog/reference: none`).
3. `process_override`: `info.merge!(info_override)` (admin).

`emoji_reaction_type` becomes `custom` when any of: NodeInfo `metadata.features` contains `pleroma_custom_emoji_reactions`, `custom_emoji_reactions`, `emoji_reaction`; instance API `fedibird_capabilities` contains `emoji_reaction`; instance API `configuration.reactions.max_reactions` is present (glitch-soc); upstream is `misskey`. It becomes `unicode` when `metadata.features` contains `pleroma_emoji_reactions`. Otherwise `none`. `emoji_reaction_max` is never inferred except by the `birdsitelive` rule. `favourite` is `false` for upstream `misskey`, else `true`. After the merge, the source of a value (declared by the server, inferred by a rule, or set by an admin) is lost. Only the merged `info` JSON remains.

State that matters for "unknown": no `nodes` row for the domain; a row whose `nodeinfo` is `{"error":"missing"}` or NULL (`Node#missing?`); `status` not `up`; `last_fetched_at` stale (`possibly_stale?` is one day); a row whose `info` has no `emoji_reaction_type`. `Node#available?` also reads Redis (`DeliveryFailureTracker.available?`) and a domain-block check, which are per-domain lookups that must not run per status.

`Account` reaches the Node through `belongs_to :node, primary_key: :domain, foreign_key: :domain` (`app/models/concerns/account_associations.rb`). Nothing in the status serialization path preloads it.

### 1.5 Account and status constraints on writing

| Constraint | Enforced by | Layer |
|---|---|---|
| Status visible to the viewer | controller `authorize @status, :show?` (`StatusPolicy#show?`: suspended author, expiry, projection privacy, personal, mention-only, private, block and domain block) | authorization |
| Expired status | `show?` allows an expired status only if the viewer already reacted, favourited, bookmarked, or is mentioned (`expired_show?`) | authorization |
| External content (`external_projection`, `ExternalBridge::ProjectionPrivacy`) | `ExternalBridge::Guards.reject_target!` raises a validation error (422) | service |
| Viewer disabled reactions | controller only (F7) | controller |
| Per-account cap, local reactor | `EmojiReactionValidator`: `[MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max`, default 1, up to `MAX_PER_ACCOUNT_LIMIT` (20) | validator |
| Per-account cap, remote reactor | same validator, fixed `MAX_PER_ACCOUNT_LIMIT` (20) | validator |
| Emoji known | validator: unicode must be in `emoji_map.json`; custom must resolve | validator |
| Remote custom emoji only if already on the status | service no-op (F10) | service |
| Author silenced | skips delivery only (F13) | service |
| Per-status "do not allow reactions" override | does not exist | n/a |
| Target Node support | not checked on write; it only picks the activity type | service |

Errors map through `Api::BaseController`: `RecordInvalid` and `ValidationError` become `422 {"error": "..."}`, `NotPermittedError` becomes `403 {"error": "This action is not allowed"}`, `RecordNotFound` becomes `404`. The limit message is the locale string `reactions.errors.limit_reached`.

### 1.6 Settings, read and write paths

| Setting | Storage and access | Notes |
|---|---|---|
| `disable_reactions` | `settings` row (`thing_type=User`) through `User#setting_disable_reactions`, default in `config/settings.yml`, written by the Rails safety preferences form through `UserSettingsDecorator` | Catalog entry `user.disable_reactions` in `docs/settings_service/catalog.yml`: `candidate_high_risk`, `apply_hint: reinitialize`. The WebUI captures it at module load (`initial_state.js`: `disableReactions`), so a change does not reach an open WebUI. It also disables favourite, boost, and polls (`status_action_bar.js`, `status_content.js`). |
| `enable_reaction` | same | Display and notification toggle for the viewer. `UserSettingsDecorator#profile_change?` treats it as a profile key (triggers an ActivityPub profile update distribution). |
| `reaction_max_per_account` | site `Setting` (`config/settings.yml`, admin form `Form::AdminSettings`, 1 to 20) | Surfaced to clients as `max_reactions_per_account` in `/api/v1/instance` (both serializers) and in InitialState `emoji_reactions`. |
| `hide_list_of_emoji_reactions_to_posts`, `hide_reaction_counter` | same as `disable_reactions` | Read paths only. `Statuses::EmojiReactionedByController` returns an empty list when set. |
| Fallback policy | does not exist | |

The Settings Service (`app/lib/user_preferences/*`, `GET/PATCH /api/v1/fedibird/preferences`, `docs/settings_service/decisions.md`) currently serves nine general keys (`UserPreferences::Reader::KEYS`). Decision D2 keeps high-risk keys (operation prohibitions and "ActivityPub delivery targets") off the general write port. A fallback policy is both, so it is high-risk (section 6.1).

### 1.7 Read paths and REST serializers

| Path | What it does with reactions |
|---|---|
| `REST::StatusSerializer` | `emoji_reactions` = `object.grouped_emoji_reactions(current_user&.account)`; `emoji_reactions_count`; `emoji_reactioned` (viewer-only, from `relationships.emoji_reactions_map`, else a per-status `exists?` query). No Node data, no limit data. |
| `Status#grouped_emoji_reactions(account)` | Parses the JSON cache in `status_stats.emoji_reactions_cache`, then per viewer sets `me` and strips excluded accounts (`excluded_from_timeline_account_ids`, domain exclusions, silenced accounts). It issues account lookups per reaction group per status for the viewer, which is not batched across a page. |
| `StatusRelationshipsPresenter` | One SQL statement per page. Reactions are `string_agg(status_id)` over `emoji_reactions where account_id = viewer` and become a boolean map `emoji_reactions_map`. It carries no per-status count. |
| `Statuses::EmojiReactionedByController`, `Api::V1::EmojiReactionsController#index`, `EmojiReactionEmojisController` | Lists of reactors, of reacted statuses (viewer-scoped, with the projection privacy relation), and of emoji. |
| `REST::NodeSerializer` | `emoji_reaction_type`, `emoji_reaction_max` (falls back to `1`), `referencability` and neighbors (fall back to `:public`). Unused (F6). |
| `StatusPolicy#expired_show?` | Reads `emoji_reactions_map` from the preloaded relations. |
| Instance serializers | `max_reactions` (`LIMIT`, 20) and `max_reactions_per_account` (site cap). |

Caching: `cache_collection` does not cache serialized output. `cache_if_unauthenticated!` applies a 15 second public cache to unauthenticated responses only. Authenticated responses are not publicly cacheable, so a viewer-specific status field is safe in REST as long as it is absent when `current_user` is nil.

### 1.8 Streaming: shared and per-viewer payloads

| Path | Rendering | Viewer-specific fields |
|---|---|---|
| `FanOutOnWriteService#render_anonymous_payload` and `render_anonymous_reblog_payload` | `InlineRenderer.render(status, nil, :status)`, once, shared by every recipient and by public, tag, and list channels | No. `current_user` is nil, so `favourited`, `emoji_reactioned`, `filtered` and similar are omitted by `if: :current_user?`. |
| `PushUpdateWorker`, `PublishStatusUpdateWorker` | `InlineRenderer.render(status, account, :status)` per recipient, published to `timeline:<account id>` | Yes. |
| `PublishEmojiReactionWorker` | Builds a `GroupedEmojiReactionSerializer` payload `{name, count, account_ids, status_id}` and publishes to each subscribed active account. The `after_commit :queue_publish` hook in `EmojiReaction` is commented out, so it is not currently reached. | n/a |
| `NotifyService` | per-recipient notification payload | Yes. |
| `streaming/index.js` | Passes payloads through. Filters `update` and `status.update` events; checks notification types for the Statuzer client. It does not rewrite statuses. | n/a |

Any new viewer-sensitive field is only safe when it is `if: :current_user?`-gated, which the anonymous renderer already satisfies, and the client must treat "field absent" as "unknown", not as "false" (same convention as `favourited`).

### 1.9 Existing client interfaces

| Client code | Behavior |
|---|---|
| `actions/interactions.js` (`addEmojiReaction`, `removeEmojiReaction`) | `PUT` and `DELETE` the REST routes; on success `importFetchedStatus(response.data)`. Errors only dispatch `EMOJI_REACTION_FAIL`; no error body handling, no confirmation step. |
| `containers/status_container.js`, `features/status/index.js` | `reactionLimitReached = myCount >= maxReactionsPerAccount` (F11). |
| `components/status_action_bar.js`, `features/status/components/action_bar.js` | The reaction button is disabled by `disableReactions`, `expired`, `anonymousAccess`, `externalContent`, `reactionLimitReached`. |
| `components/emoji_reactions.js` | Each chip is disabled by `disableReactions` or (`!myReaction && reactionLimitReached`). |
| `reducers/statuses.js` | Optimistic add and remove of `me` on `EMOJI_REACTION_REQUEST` and `UN_EMOJI_REACTION_REQUEST`; replaced by the server status on success; `emoji_reaction` streaming event updates counts. |
| Third-party clients | Use `PUT .../emoji_reactions/:id`, `/api/v1/instance` (`max_reactions_per_account`), and `emoji_reactions`, `emoji_reactioned` from statuses. They see none of: Node type, fallback, or per-status availability. |

## 2. Layers and vocabulary

Three layers stay separate and only the third is inlined in a status.

1. Node capability: what the author's server is known, inferred, or configured to do. One record per domain. Includes provenance. Never embedded in a status payload.
2. Account capability: constraints that belong to the author or the author-viewer relationship: author silenced or suspended, protocol is not ActivityPub, block, domain block. These are not Node support and they are not per-status.
3. Status interaction: the viewer-specific result for one status: can the viewer add, would it need consent, how many more, can the viewer remove.

Four sources of "no" must stay distinguishable by `reason`:

| Source | Example | Reason code |
|---|---|---|
| Node support | server has no reaction support and no Like delivery | `node_unsupported` |
| Local domain handling | local admin rejects the domain | `domain_blocked` |
| Account and relationship | author blocks viewer, author suspended | `blocked_by_author`, `account_unavailable` |
| Per-status override (future) | author or moderator disallowed reacting to this post | `status_disallowed` (reserved, no storage today) |
| Viewer choice | `disable_reactions`, fallback policy `deny` | `viewer_reactions_disabled`, `fallback_denied`, `capability_unknown_denied` |

Provenance values for Node capabilities (Node layer only): `declared` (the server said so in NodeInfo or the instance API), `observed` (seen working or failing, for example a delivery or an inbound reaction from that domain), `inferred` (a software or heuristic rule, for example "upstream is misskey"), `overridden` (admin `info_override`), `unknown`. Today's `info` can be mapped as: `info_override` key present is `overridden`; `birdsitelive` rule is `inferred`; `metadata.features` and `fedibird_capabilities` matches are `declared`; the glitch-soc `max_reactions` and `misskey` upstream matches are `inferred`; a missing key is `unknown`. `observed` has no source today.

## 3. Proposed wire schemas (versioned)

All three are additive. Names are proposals; section 12 lists what must be confirmed before they freeze. Existing Fedibird extension fields are top-level and snake_case (`emoji_reactions`, `visibility_ex`, `fedibird_external`), so the status field follows that.

### 3.1 Status: `interaction_capabilities.emoji_reaction`

Emitted only when `current_user?`, and only when the site flag is on (section 11). Never emitted by the anonymous renderer.

```json
{
  "interaction_capabilities": {
    "emoji_reaction": {
      "v": 1,
      "availability": "allowed",
      "can_add": true,
      "requires_confirmation": false,
      "can_remove": false,
      "mechanism": "native",
      "kinds": { "unicode": "native", "custom": "native" },
      "reason": null,
      "effects": [],
      "limit": {
        "local_max": 3,
        "target_max": 3,
        "current": 0,
        "remaining": 3,
        "remaining_exact": true
      }
    }
  }
}
```

Field semantics:

| Field | Type | Meaning |
|---|---|---|
| `v` | integer | Schema version of this object. Clients ignore unknown values of `v` greater than they support, and fall back to today's behavior. |
| `availability` | `allowed` \| `confirm` \| `limit_reached` \| `disabled` \| `unsupported` \| `unknown` | Display and diagnostics. Clients decide behavior from `can_add` and `requires_confirmation`, not from this string. |
| `can_add` | boolean | The viewer may add a reaction after any required confirmation. `false` means the write would be refused. It is never `null`. |
| `requires_confirmation` | boolean | An explicit per-action consent (section 6.3) is required before the write. Only `true` when `can_add` is `true`. |
| `can_remove` | boolean | The viewer has at least one reaction row on `status.proper`. Independent of `can_add`, of `disable_reactions`, and of the fallback policy. |
| `mechanism` | `native` \| `like_fallback` \| `unknown` \| `none` | How the reaction would be delivered, for the best available emoji kind. `none` means no delivery mechanism, the reaction would be local-only or refused (see `availability`). |
| `kinds` | object | The same mechanism values per emoji kind (`unicode`, `custom`). Required because a `unicode`-only Node cannot take a custom emoji natively. `mechanism` is the best of the two. |
| `reason` | string or `null` | A code from the table in section 2, plus `limit_reached_local` and `limit_reached_target`. `null` when `availability` is `allowed`. |
| `effects` | array of string | Side effects the viewer should be told about. Currently only `remote_favourite` (the author's server may show this as a favourite). Empty for `native`. |
| `limit` | object | See section 4. |

`availability` and the two booleans are tied as follows (the resolver must produce exactly these):

| `availability` | `can_add` | `requires_confirmation` |
|---|---|---|
| `allowed` | true | false |
| `confirm` | true | true |
| `unknown` | true | false (only when the fallback policy is `allow`; with `ask` it is `confirm`, with `deny` it is `disabled`) |
| `limit_reached` | false | false |
| `disabled` | false | false |
| `unsupported` | false | false |

Compact size: about 250 bytes per status for the example above. Section 10 sets the budget.

More examples (only the changed fields are shown; `v`, `can_remove`, `kinds` follow the same rules).

Native `EmojiReact`, Node declares a limit of 1 and the viewer already used it:

```json
{ "availability": "limit_reached", "can_add": false, "requires_confirmation": false,
  "can_remove": true, "mechanism": "native", "reason": "limit_reached_target",
  "limit": { "local_max": 3, "target_max": 1, "current": 1, "remaining": 0, "remaining_exact": true } }
```

Like fallback, policy `allow`:

```json
{ "availability": "allowed", "can_add": true, "requires_confirmation": false,
  "mechanism": "like_fallback", "kinds": { "unicode": "like_fallback", "custom": "like_fallback" },
  "reason": null, "effects": ["remote_favourite"],
  "limit": { "local_max": 3, "target_max": null, "current": 0, "remaining": 3, "remaining_exact": false } }
```

Like fallback, policy `ask`:

```json
{ "availability": "confirm", "can_add": true, "requires_confirmation": true,
  "mechanism": "like_fallback", "reason": null, "effects": ["remote_favourite"] }
```

Like fallback, policy `deny`:

```json
{ "availability": "disabled", "can_add": false, "requires_confirmation": false,
  "mechanism": "like_fallback", "reason": "fallback_denied", "effects": ["remote_favourite"] }
```

Unsupported (`emoji_reaction_type: none` and no Like delivery, for example `birdsitelive`):

```json
{ "availability": "unsupported", "can_add": false, "requires_confirmation": false,
  "mechanism": "none", "kinds": { "unicode": "none", "custom": "none" },
  "reason": "node_unsupported", "effects": [] }
```

Unknown (no Node row or no NodeInfo), policy `allow`:

```json
{ "availability": "unknown", "can_add": true, "requires_confirmation": false,
  "mechanism": "unknown", "reason": null, "effects": ["remote_favourite"],
  "limit": { "local_max": 3, "target_max": null, "current": 0, "remaining": 3, "remaining_exact": false } }
```

Exhausted local limit on a native server:

```json
{ "availability": "limit_reached", "can_add": false, "requires_confirmation": false,
  "can_remove": true, "mechanism": "native", "reason": "limit_reached_local",
  "limit": { "local_max": 3, "target_max": 5, "current": 3, "remaining": 0, "remaining_exact": true } }
```

### 3.2 Node capabilities (future, P3)

Detailed, with provenance, never inlined in statuses. Names `emoji_reaction_type` and `emoji_reaction_max` stay the same as the unused `REST::NodeSerializer` so there is one vocabulary.

```json
{
  "domain": "example.social",
  "v": 1,
  "fetched_at": "2026-10-25T09:00:00Z",
  "stale": false,
  "reachability": "up",
  "capabilities": {
    "emoji_reaction": {
      "type":              { "value": "custom", "source": "declared" },
      "max_per_account":   { "value": null,     "source": "unknown" },
      "like_fallback":     { "value": true,     "source": "inferred" },
      "kinds":             { "unicode": "native", "custom": "native" }
    },
    "favourite": { "value": true,  "source": "inferred" },
    "reply":     { "value": true,  "source": "unknown" },
    "reblog":    { "value": true,  "source": "unknown" },
    "reference": { "value": true,  "source": "unknown" }
  }
}
```

A batch form takes up to 100 domains and returns the same objects keyed by domain. `max_per_account.value` is `null` when no source states it. The default must not be copied from the local site cap (F5). Storing provenance needs a data change in P3 (either a `capabilities` JSONB beside `info`, or per-key source markers); P3 must also decide how `info_override` keeps winning without erasing the lower-ranked evidence.

### 3.3 User `fallback_policy`

```json
{ "emoji_reaction_fallback_policy": { "v": 1, "value": "ask", "source": "default" } }
```

`value` is `allow`, `ask`, or `deny`. `source` is `user` (a stored row), `default` (the shipped default), or `grandfathered` (section 6.2). It applies to the Like fallback delivery of an emoji reaction only. It does not apply to native `EmojiReact`, and it does not apply to the user's own favourites. Storage and exposure are in section 6.1.

## 4. Limit semantics

Fields and how each can be known:

| Field | Definition | Source | Exact? |
|---|---|---|---|
| `local_max` | Per-account cap enforced by this server: `[MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max` | site `Setting`, read at request time (not the `Node::FEATURES` constant, F5) | Yes |
| `target_max` | Per-account cap the author's server accepts | Node capability, `null` when no source states it | Only when non-null |
| `current` | Viewer's `EmojiReaction` rows on `status.proper` | database | Yes, as a local fact. It is not proof that the author's server accepted or displays them. |
| `local_remaining` | `max(0, local_max - current)` | derived | Yes |
| `target_remaining` | `target_max.nil? ? nil : max(0, target_max - current)` | derived | Only when `target_max` is non-null |
| `remaining` | `[local_remaining, target_remaining].compact.min` | derived | See `remaining_exact` |
| `remaining_exact` | `target_max` is non-null | derived | n/a |
| `per_status_distinct_max` (not in v1) | 20 distinct names visible per status (F9). A display cap, not a write cap. | `EmojiReactionValidator::LIMIT` | Yes, but excluded from v1 payload; see open question Q9 |

Rules:

1. Unknown stays `null`. `target_max` is never defaulted to 1 or to `local_max`.
2. `remaining` is an upper bound on additions this server will attempt. When `remaining_exact` is `false`, clients must not show it as a guarantee ("up to N").
3. For Like fallback `target_max` is `null` unless a Node source states otherwise. The design does not promise that more than one Like counts. A remote server that deduplicates favourites will show a single favourite however many reactions are sent (see counterexample C2).
4. `limit_reached` is only reported when `remaining == 0` and no higher-priority block applies (section 7 priority).
5. A local count can accurately serve `local_max`, `current`, `local_remaining`. It cannot serve `target_max`, `target_remaining`, or "how many the author's server shows for me", because there is no delivery receipt, no ack from the author's server, and no tracking of delivery type per reaction (Q5, section 6.4). Delivery failure data (`DeliveryFailureTracker`) is per domain and not per activity.

Truth table. `local_max = 3` unless stated, viewer `current` rows on the status:

| Mechanism | `target_max` | `current` | `local_remaining` | `target_remaining` | `remaining` | `remaining_exact` | Result |
|---|---|---|---|---|---|---|---|
| native | 5 | 0 | 3 | 5 | 3 | true | can add (local cap binds) |
| native | 5 | 3 | 0 | 2 | 0 | true | `limit_reached_local` |
| native | 1 | 1 | 2 | 0 | 0 | true | `limit_reached_target` |
| native | 1 | 0 | 3 | 1 | 1 | true | can add once |
| native | null | 2 | 1 | null | 1 | false | can add; "up to 1 more" |
| native | null | 3 | 0 | null | 0 | false | `limit_reached_local` |
| like_fallback | null | 0 | 3 | null | 3 | false | can add (policy applies) |
| like_fallback | null | 1 | 2 | null | 2 | false | can add (policy applies); remote shows at most one favourite (C2) |
| like_fallback | null | 3 | 0 | null | 0 | false | `limit_reached_local` |
| like_fallback | 1 (declared or observed) | 1 | 2 | 0 | 0 | true | `limit_reached_target` |
| unknown | null | 0 | 3 | null | 3 | false | policy decides |
| unknown | null | 3 | 0 | null | 0 | false | `limit_reached_local` |
| any, `local_max = 1` | any | 1 | 0 | any | 0 | per `target_max` | `limit_reached_local` |
| none | n/a | any | n/a | n/a | n/a | n/a | `unsupported`; `limit` object omitted |
| any, remote reactor | n/a | n/a | n/a | n/a | n/a | n/a | not a viewer decision. Inbound uses the fixed cap of 20 (section 1.5). |

## 5. Resolver contract and preload plan

### 5.1 Contract

One module, `EmojiReactionCapability` (name is a proposal), with a pure core. "Pure" means: no database, Redis, network, clock, or global read inside the decision function. Everything it needs arrives in the input value, so the same function runs for one status in a write, or for a page of statuses in a serializer.

Input (value objects, immutable):

| Group | Fields | Taken from |
|---|---|---|
| Viewer | `account_id`, `disable_reactions`, `fallback_policy` (resolved, with `source`) | `User` settings, read once per request |
| Status | `proper_status_id`, `visibility`, `expired`, `external_projection`, `author_local`, `author_domain`, `author_silenced`, `author_suspended`, `author_activitypub`, `status_override` (reserved, `nil` today) | `status.proper` and its preloaded `account` |
| Relationship | `blocked_by_author`, `viewer_blocks_author`, `viewer_blocks_domain`, `domain_rejected` | preloaded account relationships, already used by `quote_muted` |
| Node snapshot | `emoji_reaction_type`, `max_per_account`, `favourite`, `reachability`, `known` (row and NodeInfo present), `software` (for the kmyblue rule) | `nodes` row, selected columns only |
| Counts | `current` | preloaded count per `proper_status_id` |
| Site | `local_max`, `resolver_enabled` flags | `Setting`, read once per request |

Output `Decision` (value object): `availability`, `can_add`, `requires_confirmation`, `can_remove`, `mechanism`, `kinds`, `reason`, `effects`, `limit`, and `delivery_plan` for the write side:

`delivery_plan(decision, emoji_kind)` returns `{ activity_type: 'EmojiReact' | 'Like' | nil, audience: :author_inbox | :followers_and_mentions | :none }`. The write services (`EmojiReactionService`, `UnEmojiReactionService`, and `CustomEmojiDistributionWorker` for the per-Node split) take the activity type from this one function, so create and undo cannot disagree (F1) and fan-out and single delivery cannot disagree (F4). The kmyblue rule becomes data in the Node snapshot (`mechanism_override: like_fallback`) and not code in a service.

Entry points: `Resolver.call(input)` and `Resolver.call_many(inputs)` (same result as mapping `call`, no per-item I/O). The Node rule that turns a Node row into a snapshot (`NodeCapability.snapshot(row)`) also lives here and is the only place that reads `info['emoji_reaction_type']`. It treats a missing key as `unknown`, not as `custom` (answers F3 and F4 with one rule).

Decision order (first match wins). This is the priority used by the decision table in section 7:

1. `disabled`: viewer `disable_reactions`; external content; status unavailable (not a decision input, `show?` answers it first); `blocked_by_author`; `viewer_blocks_author`; `domain_rejected`; `status_override` forbids.
2. `unsupported`: author is not ActivityPub, or Node type `none` with `favourite == false` (no Like delivery), or Node `reachability == gone`.
3. `limit_reached`: `remaining == 0`.
4. Mechanism, then consent: `native` is `allowed`. `like_fallback` and `unknown` consult the policy: `allow` is `allowed` (or `unknown` for an unknown mechanism, section 3.1), `ask` is `confirm`, `deny` is `disabled` with `fallback_denied` (or `capability_unknown_denied` when the mechanism is unknown).

A local author and a local reactor is always `native`: the reaction is local, and remote fan-out is per receiving Node, not per status viewer. The resolver reports `native` with an empty `effects`; per-receiver outcomes are federation facts, not viewer decisions (section 8).

### 5.2 Preload plan (no per-status database calls)

For a page of N statuses by D distinct author domains:

| Need | How | Added queries |
|---|---|---|
| Viewer settings | read `User` settings once at the start of the request; keep in a request-local struct | 0 beyond the settings load that the request already does (`ScopedSettings` also writes through `Rails.cache`; the read path is to be confirmed in P1a) |
| `proper` statuses and their accounts | `Status.with_accounts` or the existing `includes(:account)`; use `status.proper.account`. The wrapper's author is the booster. | 0 (already loaded) |
| Node snapshots | `Node.where(domain: domains).select(:id, :domain, :info, :status, :last_fetched_at, :updated_at)` once; exclude `nodeinfo` and `instance_data`, which are large | +1 per page |
| Counts | extend the existing `StatusRelationshipsPresenter` statement with `select status_id, count(*) ... group by status_id` for the viewer, replacing the boolean map with a count map (keep the boolean derived from it so `emoji_reactions_map` readers do not change) | +0 (same statement) |
| Relationships | reuse `account_relationships` (blocking, blocked_by, domain_blocking) already passed to `REST::StatusSerializer` | +0 |
| Reachability | do not call `Node#available?` per status (it reads Redis and domain blocks). Use `Node.status` only. A batched Redis lookup is a P3 option. | 0 |

Budget: at most +1 query per page and no query that grows with N or D. The presenter stays the single owner of per-viewer maps; the serializer reads the resolver result from `relationships`, as it does for `favourites_map`, so there is no fallback to a per-status query. When a serializer is built without `relationships` (single-status endpoints), the resolver runs for one status through the same code with one Node lookup. That path is allowed one extra query and must be marked in the spec.

## 6. Settings enforcement

### 6.1 Persistence

`emoji_reaction_fallback_policy` is stored as a User setting (`settings` table) and read through `User#setting_emoji_reaction_fallback_policy`, with the shipped default in `config/settings.yml`. It is added to the Rails safety preferences form next to `disable_reactions`, the `UserSettingsDecorator` allow-list, and `docs/settings_service/catalog.yml` as `candidate_high_risk` (it changes ActivityPub delivery, as D2 describes). The catalog is generated by `script/build_settings_service_catalog.rb` and checked by `script/check_settings_service_catalog.rb`; P1 must run both.

Exposure: InitialState metadata for the WebUI and `GET /api/v1/fedibird/preferences` as read-only. A high-risk write path over the API is out of scope for P1 and P2. It is not a general key under D2. Third-party clients can see the value and the per-status decision, but cannot change it.

The WebUI captures settings at module load, so an open page can hold a stale policy (the same limit as `disable_reactions`). The per-status decision and the server are the authority; the stale local value is never used for a safety decision.

### 6.2 Default and compatibility (see Q1)

Today every non-native reaction is delivered as a `Like` without asking: the current behavior equals `allow`. A shipped default of `ask` therefore changes behavior for every existing user and for every client that calls `PUT .../emoji_reactions/:id` and does not know the confirmation handshake. The review has to choose. The design recommends:

1. P1 ships enforcement with the effective default `allow` for everyone, so nothing changes until the setting and the dialog exist.
2. Before the default flips, the shipped default is `ask` for accounts created after a cutover timestamp (a site setting), and accounts that exist at cutover read as `allow` with `source: grandfathered`. No data migration over existing rows is needed, and `grandfathered` is visible, so it can be audited and later retired.
3. A user who has a stored value always wins.

Alternatives set aside: an immediate `ask` for everyone (breaks existing third-party clients and the WebUI before a dialog exists); a data migration that writes `allow` rows (a large write with no review value and an irreversible loss of the "never chose" signal).

### 6.3 First-party and third-party writes: explicit consent for `ask`

The prompt in the UI alone is not an enforcement. The server decides, and every writer goes through one gate.

Gate: `EmojiReactionService#call` takes a keyword `fallback_consent:` and asks the resolver for the decision for exactly the status and emoji it is about to write. It does this inside the service so a new controller or job cannot skip it (F7). `disable_reactions` moves into the same gate and stays enforced in the controller during the transition.

| Decision | Request has valid consent | Write result |
|---|---|---|
| `allowed` | n/a | Proceeds. |
| `confirm` | no | Refused with `409` and a confirmation token (section 8). Nothing is written. |
| `confirm` | yes | Proceeds with `like_fallback`. |
| `disabled` (`fallback_denied`) | any | Refused `403`. A consent token cannot override `deny`. |
| `unknown` (policy `allow`) | n/a | Proceeds. |
| `limit_reached`, `unsupported` | any | Refused `422`. |

Consent mechanism (recommended): a two-step handshake with a signed, short-lived token.

1. The client calls the existing `PUT` without consent. If the decision is `confirm`, the server answers `409` with `error_code: fallback_confirmation_required`, `details` (mechanism, effects) and `confirmation_token`.
2. The client shows the prompt, and on acceptance repeats the same `PUT` with `fallback_confirmation=<token>`.
3. The token is signed with `ActiveSupport::MessageVerifier`, purpose `emoji_reaction_fallback`, and binds `user_id`, `proper_status_id`, the emoji kind, the mechanism, the target domain, and an expiry (a few minutes). A token for another status, user, mechanism or after expiry is invalid and returns `409` again, not `403`.

What this guarantees and what it does not: the server never delivers a fallback Like for `ask` without a token that the server issued for that exact action, and `deny` can never be bypassed. A client that retries automatically without asking the user still gets through, because the server cannot see the user. That is the same trust boundary as any OAuth client acting for a user, and it is why `deny` (hard, server-enforced) exists next to `ask` (a protocol handshake). The WebUI is the only client that this design requires to show a dialog.

Set aside: a plain boolean parameter `confirm_fallback=true` (a third-party client can send it on every request, so `ask` degenerates to `allow` and the user-facing meaning is lost); a stored "consent per domain" row (new data and an unclear lifecycle); trusting the client-side policy value (stale, forgeable).

### 6.4 `deny` and removal, and what the write service must record

`deny` applies to the write service (not only the UI). It refuses adding a reaction that would be delivered as a fallback `Like`. It never blocks removal, and never blocks a native reaction.

Undo symmetry needs a fact that is not stored today: how a given reaction was delivered. Today undo recomputes from the current Node, so a Node that changes between create and undo, or the rule differences in F1, send the wrong activity. The design proposes a nullable `emoji_reactions.delivery` column in P1 (values `native`, `like_fallback`, `local_only`, `NULL` for rows that predate it), written at create and read by `UnEmojiReactionService`. For `NULL` rows undo keeps the current rule, but through the shared `delivery_plan`. This is a schema change, so it is not in P0 (Q5).

## 7. Decision table

Rows are evaluated in this order. `remaining` is greater than 0 unless stated. `current` is the viewer's reaction count. "Write" is the result of the REST write with the policy and token shown.

Hard blocks and unsupported (policy independent):

| # | Mechanism | Policy | Other state | `availability` | `reason` | Write |
|---|---|---|---|---|---|---|
| H1 | any | any | `disable_reactions = true` | `disabled` | `viewer_reactions_disabled` | 403 |
| H2 | any | any | author blocks viewer, or viewer blocks author or domain, or domain rejected | `disabled` | `blocked_by_author` / `domain_blocked` | 404 (not visible) or 403 |
| H3 | any | any | external content | `disabled` | `external_content` | 422 (existing guard) |
| H4 | `none` | any | Node type `none` and Like not accepted (`favourite = false`) | `unsupported` | `node_unsupported` | 422 |

Like fallback and unknown (policy matters):

| # | Mechanism | Policy | `current` / `remaining` | `availability` | `can_add` | `requires_confirmation` | Write without token | Write with token |
|---|---|---|---|---|---|---|---|---|
| F1 | `like_fallback` | `allow` | 0 / >0 | `allowed` | true | false | 200 | 200 |
| F2 | `like_fallback` | `ask` | 0 / >0 | `confirm` | true | true | 409 `fallback_confirmation_required` | 200 |
| F3 | `like_fallback` | `deny` | 0 / >0 | `disabled` (`fallback_denied`) | false | false | 403 `fallback_denied` | 403 |
| F4 | `like_fallback` | `allow` or `ask` | any / 0 | `limit_reached` | false | false | 422 `limit_reached` | 422 |
| F5 | `like_fallback` | `deny` | any / 0 | `disabled` (`fallback_denied`), a block outranks the limit | false | false | 403 | 403 |
| F6 | `like_fallback` | `allow` | >0 / >0 (C2) | `allowed` | true | false | 200, delivery per Q4 | 200 |
| U1 | `unknown` | `allow` | 0 / >0 | `unknown` | true | false | 200, delivery per Q3 | 200 |
| U2 | `unknown` | `ask` | 0 / >0 | `confirm` | true | true | 409 | 200 |
| U3 | `unknown` | `deny` | 0 / >0 | `disabled` (`capability_unknown_denied`) | false | false | 403 | 403 |
| U4 | `unknown` | any | any / 0 | `limit_reached` | false | false | 422 | 422 |

Native (policy independent):

| # | Mechanism | Policy | `current` / `remaining` | `availability` | Write |
|---|---|---|---|---|---|
| N1 | `native` | any | any / >0 | `allowed` | 200 |
| N2 | `native` | any | any / 0 | `limit_reached` (`limit_reached_local` or `limit_reached_target`) | 422 |
| N3 | `native` (unicode only) with a custom emoji | per the Node kinds | `kinds.custom` is `like_fallback` or `none`, so the custom emoji row follows F1 to F5 or H4 | | |

Removal (independent of everything above):

| # | State | `can_remove` | Remove result |
|---|---|---|---|
| R1 | viewer has at least one row on `status.proper`, any policy, `disable_reactions` true or false, any Node state | true | 200, undo delivered per `delivery` or the shared plan |
| R2 | no rows | false | 200 no-op (existing) |

Counterexamples the table has to survive:

- C1, add then policy change: the viewer reacted under `allow`, then set `deny`. The row stays, `can_remove` is true, removal works, and a later add is refused. Undo must send the same type that create sent.
- C2, many Likes, one favourite: a Like-fallback server that deduplicates favourites keeps a single favourite for the viewer on that status however many reactions were sent. Upstream Mastodon does this for `Like`. This is not verified against any implementation in this repository and must be confirmed with fixtures in P1. The 2nd to Nth reaction therefore delivers nothing the author can see, and an `Undo(Like)` for any one of them removes the single favourite while the viewer still has other reactions.
- C3, real favourite plus fallback: the viewer favourited the status and then reacted through the fallback. On a deduplicating server, undoing the reaction removes the favourite. Mitigation to evaluate: do not send `Undo(Like)` while a local `Favourite` exists, and send it only when the last fallback-delivered reaction goes. `effects: ["remote_favourite"]` exists so the confirmation text can warn about this.
- C4, native claimed, server rejects: a `declared` capability can be wrong or can change. A native `EmojiReact` can be dropped by the author's server and the viewer's local row still exists. `can_add: true` is a statement about this server's acceptance, not about the author's server (section 8).
- C5, undo after capability change: the Node was `custom` at create and `none` at undo, or the reverse. Without `delivery` on the row, the undo type is chosen from the new state.
- C6, concurrent adds: two requests both see `remaining = 1`. The resolver cannot prevent that; the write must still enforce the cap (section 8, race).
- C7, reblog: the viewer reacts on a boost. The row is for the original and the author is the original's author. The resolver must take `status.proper`. A decision that used the booster's Node would mis-decide.

## 8. Failures, errors, and the authority of the write

The write path is authoritative. A decision in a status payload is a hint computed earlier.

### 8.1 API errors

Existing errors keep their status and `error` string. New responses add `error_code` and optionally `details`; clients that do not know them keep working.

| Situation | HTTP | `error_code` | `details` |
|---|---|---|---|
| `disable_reactions` | 403 (existing) | `viewer_reactions_disabled` | none |
| fallback policy `deny` | 403 | `fallback_denied` | `{ "mechanism": "like_fallback" }` |
| unknown capability, policy `deny` | 403 | `capability_unknown_denied` | none |
| `ask` without a valid consent | 409 | `fallback_confirmation_required` | `{ "mechanism", "effects", "confirmation_token", "expires_in" }` |
| invalid or expired consent | 409 | `fallback_confirmation_invalid` | a new token |
| limit reached (local or target) | 422 (existing) | `limit_reached` | `{ "local_max", "target_max", "current" }` |
| node unsupported | 422 | `node_unsupported` | none |
| status not visible | 404 (existing) | none | none |
| external content | 422 (existing) | none | none |
| emoji not available (the silent no-op F10) | 422 | `emoji_not_available` | none. This changes a `200` to a `422`; Q8. |

`409` is chosen over `428` because most clients already show the body of a 4xx response and do not special-case `428`; this is the recommendation and it is open (Q6).

The success response is the existing status JSON, with a fresh `interaction_capabilities` when the flag is on. An error response that depends on stale state can carry the current decision in `details` so the client can update without another request.

### 8.2 Local acceptance, remote outcome, race

- Accepting a write means this server stored the reaction, and, if delivery was planned, queued it (`ActivityPub::DeliveryWorker.perform_async`). It does not mean the author's server accepted or shows it (F13, C4). The API does not report a remote outcome. A future `delivered` or `rejected` signal needs delivery receipts and is out of scope.
- No synchronous remote request happens during status serialization or during resolution. Node data is read from the database only. A stale or unknown Node can queue a background `UpdateNodeService` call (rate-limited per domain); the decision for the current request does not wait for it.
- Race: the resolver result is not a reservation. The write re-checks the cap. Today the validator counts and inserts without a lock (F8). P1 should make the cap check atomic with the insert (for example a lock on the viewer's rows for that status, or a serialized section keyed by `(account_id, status_id)`), and treat a lost race as `limit_reached`. The unique index already makes the duplicate-name race safe.
- An error always wins over the payload: if the decision said `allowed` and the write says `limit_reached`, the client shows the write result and refreshes the status.

## 9. Backwards compatibility, cache, ETag, and invalidation

Compatibility:

- Additive only. No existing field is removed or retyped. `emoji_reactions`, `emoji_reactioned`, `/api/v1/instance` `max_reactions_per_account` stay as they are.
- A client that ignores `interaction_capabilities` behaves as today. A client that reads it must treat an absent field as "unknown" and keep its current local logic.
- Existing write requests keep working under policy `allow`. They only meet `409` after the default has been flipped for an account (section 6.2).
- The WebUI keeps `reactionLimitReached` until P2 replaces it for statuses that carry the field.

Cache and ETag:

- REST: no server-side cache of decisions. They are computed on read from preloaded data (section 5.2), so they cannot be stale on the server side. Authenticated REST responses are not publicly cacheable, and `cache_if_unauthenticated!` only applies without a user. The field is absent when `current_user` is nil, so a cached public response cannot leak a viewer decision.
- Streaming: the field is never added to a shared payload. The anonymous renderers (`FanOutOnWriteService`) emit no field because `current_user` is nil. Per-account payloads (`PushUpdateWorker`, `PublishStatusUpdateWorker`) would carry it. The client importer must not replace a known decision with an absent one when a shared payload arrives; this is the same rule needed for `favourited`, and P2 must check how `reducers/statuses.js` and the importer merge (Q10).
- ETag: this API does not use ETags for authenticated status JSON, so none is added. If one is introduced later, it must include the inputs listed below.

What invalidates a decision (and who tells the client):

| Input changes | Effect | Client learns by |
|---|---|---|
| viewer adds or removes a reaction | `current`, `remaining`, `can_remove` | the write response (a full status) |
| viewer changes fallback policy or `disable_reactions` | `availability`, `can_add`, `requires_confirmation` | InitialState on reload, or the next status fetch; the write is authoritative meanwhile |
| site `reaction_max_per_account` changes | `local_max`, `remaining` | next status fetch; also stop reading the class-load constant (F5) |
| Node row changes (`UpdateNodeService`, admin override) | `mechanism`, `target_max`, `kinds` | next status fetch |
| block, mute-domain, domain block | `disabled` | next status fetch; `show?` answers visibility first |
| status expires or is edited | `disabled` or status unavailable | next status fetch |

There is no push invalidation in P1 or P2. Short-lived staleness is accepted because the write re-decides.

Failure of the resolver: a resolver exception or missing preload must not break the status. The serializer omits `interaction_capabilities` (client falls back to current logic) and counts the failure. The write path fails closed for the decision it cannot compute only when the policy is `deny` or `ask`; with `allow` it proceeds as today. This keeps `allow` behavior identical to the current code during rollout.

## 10. Tests and measurements required before enabling status-inline fields

Tests (all required before the flag in section 11 is turned on in P2):

1. Resolver unit tests: every row of sections 4 and 7 as a table-driven spec, including the priority order (`disable_reactions` over `unsupported` over `limit_reached` over policy) and the `availability` to booleans mapping in section 3.1.
2. Node snapshot tests: missing row, `nodeinfo` missing, key absent, `none`, `unicode`, `custom`, `birdsitelive`, `kmyblue`, override winning, `gone`. Assert that an absent key is `unknown`, not `custom`.
3. Delivery-plan parity tests: for every Node snapshot and emoji kind, `EmojiReactionService`, `UnEmojiReactionService`, and `CustomEmojiDistributionWorker` pick the same activity type for the same reaction (F1, F4). Includes the create then undo case with a Node change between (C5).
4. Contract test between resolver and write: for every generated input where the resolver says `can_add && !requires_confirmation`, the service creates the row, and where it says `deny` or `unsupported`, no delivery job is enqueued.
5. Query-count tests: a page of 40 statuses from 40 different domains, and from 1 domain, with and without a reblog, adds at most the budgeted queries (section 5.2) and the count does not grow with N or D. Anonymous requests add none.
6. Serializer tests: field absent when `current_user` is nil, when the flag is off, and in the shared streaming payload (`FanOutOnWriteService` anonymous payload); present and correct for `PushUpdateWorker`.
7. Controller or request specs for every error row in section 8.1, including consent token binding (wrong status, wrong user, expired, replay after policy change to `deny`) and that removal works under `deny` and `disable_reactions`.
8. Concurrency spec for the cap (two parallel writes at `remaining = 1`, one succeeds).
9. Policy and settings specs: settings catalog regeneration and check scripts, preferences form, `UserSettingsDecorator` allow-list, default and `grandfathered` resolution, high-risk key not writable through the general preferences API.
10. Compatibility specs: an old-style client request (no token) under policy `allow` is unchanged byte for byte in status code and in existing fields.

Measurements (staging with production-shaped data, before and after, flag on and off):

| Metric | Budget (proposal) |
|---|---|
| Extra queries per page | at most 1, independent of N and D |
| Added p95 latency of `GET /api/v1/timelines/home` (40 statuses) | at most 5 percent |
| Payload growth per status | at most 300 bytes uncompressed |
| Serialization allocations per page | measured, no regression above 5 percent |
| Shadow-mode divergence: legacy sender activity type versus resolver `delivery_plan` over a representative window of real writes | reported by Node software, every divergence either explained by one of F1 to F4 or fixed before enforcement |
| Node coverage: share of author domains with a known (non-`unknown`) snapshot among statuses served | reported; this decides how often `unknown` reaches users |

## 11. Phasing, rollout and rollback

Each phase is its own PR with its own flag, and none depends on a data backfill. The recommended order differs from the P1, P2, P3 numbering in the issue for safety reasons given after the table.

| Phase | Scope | Flag and rollout | Rollback |
|---|---|---|---|
| P1a | Resolver, Node snapshot, delivery plan; shadow mode only. The services still decide as today; the resolver runs beside them and logs divergence. No API, setting, schema, or UI change. | site setting `emoji_reaction_resolver_shadow` (off by default, sampled) | turn the flag off; no persisted state |
| P1b | Fallback policy setting (high-risk, catalog entry, safety form, `allow` effective default), write gate in `EmojiReactionService`, consent handshake, error codes, shared delivery plan for create, undo, and fan-out (each F1 to F4 fix behind its own sub-flag), `emoji_reactions.delivery` column (nullable, additive) | `emoji_reaction_resolver_enforce`. Enable for staff accounts, then a percentage of accounts, then all. Default stays `allow`. | turn the flag off to restore the legacy sender and the controller-only checks. The `delivery` column is nullable and ignored; leaving it does no harm. |
| P2 | `interaction_capabilities.emoji_reaction` on REST statuses for authenticated viewers, `fallback_policy` in preferences (read-only), WebUI: disable unsupported and exhausted controls from the decision, confirmation dialog for `confirm`, error code handling. Streaming shared payloads unchanged. | `emoji_reaction_interaction_capabilities` (site), then per account. | turn the flag off: the field disappears and the WebUI falls back to `reactionLimitReached`. |
| P1c | Flip the default policy to `ask` for new accounts, with grandfathering (section 6.2). Only after P2's dialog is live in the WebUI and the compatibility measurement shows no unexpected `409`s. | cutover timestamp setting | set the cutover to the past or the default back to `allow`; stored user values are untouched |
| P3 | Node capability storage with provenance, `GET`/batch Node capability API, admin visibility of `declared`/`inferred`/`overridden`, and stop reading `FEATURES[:emoji_reaction_max]` as a remote value (F5). Replaces the unused `REST::NodeSerializer` fields. | `node_capabilities_api` | route off; additive storage stays unused |

Why not strictly P1, P2, P3: shadow mode (P1a) is a pure measurement and must come first; the default flip must come after the dialog (P1c after P2), otherwise `ask` blocks users who have no way to answer; Node provenance (P3) improves decisions but does not block P1b and P2, which can run on the coarse snapshot (`unknown` is safe), so P3 can ship last. Streaming never carries the field in any phase.

Exit criteria to move from shadow to enforcement: divergence explained; the tests in section 10 green; the query and latency budgets met. Exit criteria for P2: budgets met with the flag on for staff accounts for a measurement window, no increase in write error rate, `unknown` share reported.

## 12. Open design questions

These are not decided by this document.

| # | Question | Recommendation, if any |
|---|---|---|
| Q1 | Default policy and migration for existing users (section 6.2). | Effective `allow` first; `ask` for new accounts after cutover; grandfather existing accounts. Needs an owner decision. |
| Q2 | Final wire names: `interaction_capabilities` as a top-level status key, `emoji_reaction_fallback_policy`, error codes, `mechanism` and `kinds` values. | As written; confirm with client authors before freezing. |
| Q3 | What to send to an `unknown` Node under `allow`: `EmojiReact` (today's behavior for a Node row with empty `info`) or `Like` (today's behavior for a missing row)? | `Like` with the fallback effects, since `unknown` is never native. This changes behavior for NodeInfo-less servers; it needs shadow-mode data. |
| Q4 | Under Like fallback, should the 2nd to Nth reaction on one status send an additional `Like`? | No: send one `Like`, record the rest as local-only, and send `Undo(Like)` only when the last fallback-delivered reaction goes (C2, C3). Needs verification against remote implementations; the doc cites upstream Mastodon only from memory. |
| Q5 | Is a `delivery` column on `emoji_reactions` acceptable, or should undo keep deriving from the current Node? | Add the column (nullable, additive). Without it C5 cannot be fixed. |
| Q6 | `409` versus `428` for the consent handshake. | `409`. |
| Q7 | Is a custom emoji on a `unicode`-only Node `like_fallback` or `unsupported`? Today the service sends `EmojiReact` with `:name:` content. | Not decided; needs a fixture against a unicode-only server. |
| Q8 | Turning the silent no-op for foreign custom emoji (F10) into `422`. It is a visible API change. | Do it in P1b behind its own sub-flag. |
| Q9 | Expose the per-status distinct cap (20) and the distinct count? It needs aggregate data and is a display cap, not a write cap. | Leave out of v1. |
| Q10 | How do `reducers/statuses.js` and the importer merge a status that lacks a field present in the store (shared streaming payloads)? Not read in this inventory. | Check in P2; add a regression test. |
| Q11 | Per-status "disallow reactions": where is it stored and who sets it (author, moderator)? Should it federate? No storage or product definition exists. | Reserve `status_disallowed`; no field, no schema in P1 to P3. |
| Q12 | Inbound reactions to a local status: should the viewer setting, the per-status override, and the fallback policy apply? Today none apply (section 1.1). | Per-status override and `disable_reactions` of the author should apply to inbound; the fallback policy is about outgoing delivery only. Needs a product decision. |
| Q13 | Should `reachability` consider `DeliveryFailureTracker` (Redis) per domain? | Not in v1; use `Node.status` only; revisit with a batched lookup in P3. |
| Q14 | `kmyblue` becomes data (`mechanism_override`) in the Node snapshot. Where does the admin edit it: `info_override` or a new key? | `info_override`, documented in P3. |
| Q15 | The inbound limit for remote reactors is the fixed 20; should it follow the author's local cap for local authors? | Out of scope; recorded because it is a different limit from the viewer decision. |

## 13. Non-goals of this document

No P1 work starts from this PR. This change does not touch `app/`, `config/`, `db/`, `spec/`, `script/`, or `streaming/`. It does not edit `docs/settings_service/catalog.yml`, regenerate any generated file, change feature flags, create a migration, or deploy.
