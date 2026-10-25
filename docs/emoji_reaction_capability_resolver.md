# Emoji reaction Capability Resolver: P0 design and inventory

Issue: [fedibird/mastodon#572](https://github.com/fedibird/mastodon/issues/572)

Status: design only. This document is the whole P0 deliverable. It adds no route, column, setting, serializer field, feature flag, or WebUI behavior, and it does not migrate or deploy anything. Every behavior described in section 1 is read from the `fedibird` branch at commit `86218c57d9`. Everything from section 2 on is a proposal. Where the code was not enough to decide, the question is listed in section 12 and not guessed.

Terms: "reactor" is the account that adds a reaction. "Author" is the account that owns the status, always `status.proper.account`. "Target Node" is the `Node` row for the author's domain. "Like fallback" is delivering a reaction as an ActivityPub `Like` activity that carries `content` (and a `tag` for a custom emoji) instead of an `EmojiReact`.

Revision 2 answers the review of c656aac7. Where each point was handled:

| Review point | Handled in |
|---|---|
| 1. Per-kind and per-emoji decisions | section 3.1 (per-kind objects, aggregate rule, write-time contract), 5.1.2, 7 (rows M1 to M4) |
| 2. `favourite` normalization and H4 | F14, section 5.1.1, 5.1.2, 7 (H4, H5) |
| 3. Like aggregation and the Undo activity id | F17, section 6.4, 7 (C2, C3, C8), 11 (P1b-2 blocked), Q4, Q5, Q17, Q18 |
| 4. Shared streaming payloads | section 9.1 |
| 5. Boost wrapper and idempotent retry | F15, F16, section 8.3, 10 (7a, 7b) |
| 6. Consent token binding | section 6.3 |
| 7. `remaining_exact` and Settings Service | section 3.1, 4, 6.1 |

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
| F14 | `Node#info` values are not uniformly typed. `birdsitelive` writes the string `'none'` into `favourite`, `reply`, `reblog`, and `reference`; inference writes booleans; defaults are `true`; `REST::NodeSerializer` falls back to `:public`. A boolean test such as `favourite == false` does not match the `birdsitelive` override and does match the `misskey` family (which does receive `Like` as a reaction). | `UpdateNodeService#process_software_specific_override`, `#process_features`, `app/models/node.rb` |
| F15 | The write path is not keyed to one status id. `EmojiReactionService` finds and creates with the id it was given (`status.id`, the boost wrapper), while `EmojiReaction#before_validation` rewrites `status` to the reblogged original. `UnEmojiReactionService` filters with `where(status: status)` and the wrapper, so a delete through a wrapper matches no row. A repeated `PUT` through a wrapper does not find its existing row and ends in a limit error (422) or, with a cap above 1, in `RecordNotUnique` followed by `find_by!` with the wrapper id (404). By inspection only. | `EmojiReactionService#call`, `UnEmojiReactionService#call`, `EmojiReaction` |
| F16 | A repeated `PUT` for a reaction that already exists is not idempotent on the side effects. After the find-first lookup, `emoji_reaction.tap { create_notification; bump_potential_friendship }` runs whether or not the row is new; only the moderation event is gated on `newly_reacted`. A re-send therefore calls `NotifyService`, re-delivers or re-distributes the activity, and bumps potential friendship again. | `EmojiReactionService#call` |
| F17 | The identity of a delivered activity is the reaction row id (`<actor>#emoji_reactions/<row id>`, and `/undo` for the Undo, whose `object` is the same activity). One reaction is one activity. Any rule that sends fewer activities than rows has nowhere to keep which activity was sent. | `ActivityPub::EmojiReactionSerializer`, `ActivityPub::UndoEmojiReactionSerializer` |

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

The unit of a decision is an emoji kind, and in the end the selected emoji. The status payload carries a per-kind decision; the write path takes the decision for the emoji actually being written (contract below). Hard blocks and the limit are shared by both kinds. Mechanism, consent need, and the reasons that come from the fallback policy are per kind.

```json
{
  "interaction_capabilities": {
    "emoji_reaction": {
      "v": 1,
      "availability": "allowed",
      "can_add": true,
      "requires_confirmation": false,
      "can_remove": false,
      "reason": null,
      "kinds": {
        "unicode": { "mechanism": "native", "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null, "effects": [] },
        "custom":  { "mechanism": "native", "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null, "effects": [] }
      },
      "limit": {
        "local_max": 3,
        "target_max": 3,
        "current": 0,
        "remaining": 3,
        "target_limit_known": true
      }
    }
  }
}
```

Field semantics:

| Field | Type | Meaning |
|---|---|---|
| `v` | integer | Schema version of this object. Clients ignore an object whose `v` is greater than they support and fall back to today's behavior. |
| `kinds.<kind>` | object | The decision for one emoji kind (`unicode`, `custom`). Both keys are always present. This is what an emoji picker uses to enable or disable one emoji. Its fields are `mechanism`, `availability`, `can_add`, `requires_confirmation`, `reason`, `effects`, defined below. |
| `mechanism` (per kind) | `native` \| `like_fallback` \| `unknown` \| `none` | How a reaction of this kind would be delivered. `none` means no delivery mechanism exists (see `availability`). |
| `availability` | `allowed` \| `confirm` \| `limit_reached` \| `disabled` \| `unsupported` \| `unknown` | Display and diagnostics. Clients decide behavior from `can_add` and `requires_confirmation`, not from this string. |
| `can_add` | boolean | The viewer may add a reaction after any required confirmation. `false` means the write would be refused. Never `null`. |
| `requires_confirmation` | boolean | An explicit per-action consent (section 6.3) is required before the write. Only `true` when `can_add` is `true`. |
| `reason` | string or `null` | A code from section 2, plus `limit_reached_local` and `limit_reached_target`. `null` when `availability` is `allowed`. |
| `effects` | array of string | Side effects the user should be told about. Currently only `remote_favourite`. Empty for `native`. |
| `can_remove` | boolean | Top level only. The viewer has at least one reaction row on the canonical status (`status.proper`). Independent of `can_add`, `disable_reactions`, and the fallback policy. |
| top-level `availability`, `can_add`, `requires_confirmation`, `reason` | as above | An aggregate for the status (for example, whether to show the reaction button at all). It is the best of the two kinds in this order: `allowed`, `unknown`, `confirm`, `limit_reached`, `disabled`, `unsupported`. `can_add` is true when any kind can be added. `requires_confirmation` is true only when no kind can be added without confirmation. `reason` is taken from the chosen kind. A client must not use the aggregate to enable an individual emoji. |
| `limit` | object | Shared by both kinds. See section 4. |

Write-time contract for the selected emoji. `Resolver.call(input, emoji:)` receives the emoji (unicode string, or a resolved custom emoji) and returns the decision for it. The invariants are:

1. For an emoji of kind K the write-time decision equals `kinds[K]` of the status payload computed from the same inputs, except for emoji-specific reasons that the summary cannot express: `emoji_not_available` (a remote custom emoji not yet on the status, F10), `emoji_disabled`, and an unrecognized emoji. These reasons only exist at write time.
2. The summary is a hint. A client that disables a picker entry because `kinds[K].can_add` is false is correct; a client that enables an entry because it is true can still be refused for an emoji-specific reason or because state changed.
3. Per-emoji dry run is not part of this design (Q16). The first write attempt is the check, and a `409` or an error body carries the current per-kind decision.

`availability` and the two booleans are tied as follows, for every kind object and for the aggregate (the resolver must produce exactly these):

| `availability` | `can_add` | `requires_confirmation` |
|---|---|---|
| `allowed` | true | false |
| `confirm` | true | true |
| `unknown` | true | false (only when the fallback policy is `allow`; with `ask` it is `confirm`, with `deny` it is `disabled`) |
| `limit_reached` | false | false |
| `disabled` | false | false |
| `unsupported` | false | false |

Size: about 520 bytes per status for the example above, which is why `v` and `kinds` are the first thing the measurement budget in section 10 checks. A compact form that omits `kinds` when both kinds are identical is a possible optimization and is not part of v1.

More examples. Only the changed fields are shown; `v` and `limit` follow the same rules and `can_remove` is shown where it matters.

Mixed kinds: the Node takes `unicode` natively, `custom` needs Like fallback, policy `deny`. The aggregate is `allowed`, and writing a custom emoji is refused:

```json
{ "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null,
  "kinds": {
    "unicode": { "mechanism": "native", "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null, "effects": [] },
    "custom":  { "mechanism": "like_fallback", "availability": "disabled", "can_add": false, "requires_confirmation": false, "reason": "fallback_denied", "effects": ["remote_favourite"] }
  } }
```

Mixed kinds, policy `ask`: the unicode entry is enabled, the custom entry needs the consent handshake:

```json
{ "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null,
  "kinds": {
    "unicode": { "mechanism": "native", "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null, "effects": [] },
    "custom":  { "mechanism": "like_fallback", "availability": "confirm", "can_add": true, "requires_confirmation": true, "reason": null, "effects": ["remote_favourite"] }
  } }
```

Native `EmojiReact`, the Node states a limit of 1 and the viewer already used it:

```json
{ "availability": "limit_reached", "can_add": false, "requires_confirmation": false,
  "can_remove": true, "reason": "limit_reached_target",
  "kinds": {
    "unicode": { "mechanism": "native", "availability": "limit_reached", "can_add": false, "requires_confirmation": false, "reason": "limit_reached_target", "effects": [] },
    "custom":  { "mechanism": "native", "availability": "limit_reached", "can_add": false, "requires_confirmation": false, "reason": "limit_reached_target", "effects": [] }
  },
  "limit": { "local_max": 3, "target_max": 1, "current": 1, "remaining": 0, "target_limit_known": true } }
```

Like fallback for both kinds, policy `allow` (each kind object has `mechanism: like_fallback`, `availability: allowed`, `effects: ["remote_favourite"]`):

```json
{ "availability": "allowed", "can_add": true, "requires_confirmation": false, "reason": null,
  "limit": { "local_max": 3, "target_max": null, "current": 0, "remaining": 3, "target_limit_known": false } }
```

Like fallback for both kinds, policy `ask` (kind objects: `confirm`, `can_add: true`, `requires_confirmation: true`):

```json
{ "availability": "confirm", "can_add": true, "requires_confirmation": true, "reason": null }
```

Like fallback for both kinds, policy `deny` (kind objects: `disabled`, `reason: fallback_denied`):

```json
{ "availability": "disabled", "can_add": false, "requires_confirmation": false, "reason": "fallback_denied" }
```

Unsupported (normalized `emoji_reaction_type` is `none` and the Node explicitly rejects Like delivery, for example `birdsitelive`; kind objects: `mechanism: none`, `unsupported`, `node_unsupported`):

```json
{ "availability": "unsupported", "can_add": false, "requires_confirmation": false,
  "reason": "node_unsupported" }
```

Unknown (no Node row, or a row with no usable NodeInfo), policy `allow` (kind objects: `mechanism: unknown`, `availability: unknown`, `can_add: true`, `requires_confirmation: false`, `effects: ["remote_favourite"]`):

```json
{ "availability": "unknown", "can_add": true, "requires_confirmation": false, "reason": null,
  "limit": { "local_max": 3, "target_max": null, "current": 0, "remaining": 3, "target_limit_known": false } }
```

Exhausted local limit on a native server:

```json
{ "availability": "limit_reached", "can_add": false, "requires_confirmation": false,
  "can_remove": true, "reason": "limit_reached_local",
  "limit": { "local_max": 3, "target_max": 5, "current": 3, "remaining": 0, "target_limit_known": true } }
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

Every number in `limit` is the result of a calculation this server performs on the inputs it holds. None of them is a statement that the author's server will accept, store, or display a reaction. `limit` is shared by both emoji kinds, and `current` counts the viewer's rows of both kinds.

| Field | Definition | Source | Precision |
|---|---|---|---|
| `local_max` | Per-account cap enforced by this server: `[MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max` | site `Setting`, read at request time (not the `Node::FEATURES` constant, F5) | An exact local fact. |
| `target_max` | Per-account cap that a Node capability source states for the author's server | Node snapshot (`declared`, `inferred`, `overridden`, or `observed`), `null` when no source states it | A stated value, not a guarantee. An inferred or declared value can be wrong or can change. |
| `current` | Viewer's `EmojiReaction` rows on `status.proper` | database | An exact local fact. It is not proof that the author's server accepted or displays them. |
| `local_remaining` | `max(0, local_max - current)` | derived | Exact for the local cap. |
| `target_remaining` | `target_max.nil? ? nil : max(0, target_max - current)` | derived | As good as `target_max`. |
| `remaining` | `[local_remaining, target_remaining].compact.min` | derived | An upper bound on how many more additions this server will attempt. |
| `target_limit_known` | `target_max` is non-null | derived | Says only whether `target_max` was an input to `remaining`. It does not say the value is correct. |
| `per_status_distinct_max` (not in v1) | 20 distinct names visible per status (F9). A display cap, not a write cap. | `EmojiReactionValidator::LIMIT` | Excluded from v1; see open question Q9. |

Rules:

1. Unknown stays `null`. `target_max` is never defaulted to 1 or to `local_max`.
2. `remaining` is an upper bound on additions this server will attempt. When `target_limit_known` is `false`, clients must not show it as a guarantee ("up to N"). When it is `true`, clients may show it as "N more", but still must not describe it as what the author's server accepts.
3. For Like fallback `target_max` is `null` unless a Node source states otherwise. The design does not promise that more than one Like counts. A remote server that deduplicates favourites will show a single favourite however many reactions are sent (see counterexample C2).
4. `limit_reached` is only reported when `remaining == 0` and no higher-priority block applies (section 7 priority).
5. A local count can accurately serve `local_max`, `current`, `local_remaining`. It cannot serve `target_max`, `target_remaining`, or "how many the author's server shows for me", because there is no delivery receipt, no ack from the author's server, and no tracking of delivery type per reaction (Q5, section 6.4). Delivery failure data (`DeliveryFailureTracker`) is per domain and not per activity.

Truth table. `local_max = 3` unless stated, viewer `current` rows on the status:

| Mechanism | `target_max` | `current` | `local_remaining` | `target_remaining` | `remaining` | `target_limit_known` | Result |
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
| Node snapshot (normalized, section 5.1.1) | `emoji_reaction_type` (`custom`, `unicode`, `none`, `unknown`), `like_delivery` (`accepts`, `rejects`, `unknown`), `max_per_account` (integer or `null`), `reachability`, `software`, `mechanism_override` | `nodes` row, selected columns only, normalized by `NodeCapability.snapshot` |
| Counts | `current` | preloaded count per `proper_status_id` |
| Site | `local_max`, `resolver_enabled` flags | `Setting`, read once per request |

Output `Decision` (value object): the aggregate `availability`, `can_add`, `requires_confirmation`, `reason`; `can_remove`; `kinds` (one decision object per emoji kind, section 3.1); `limit`; and `delivery_plan` for the write side. `Resolver.call(input)` returns the status summary. `Resolver.call(input, emoji:)` returns the decision for the selected emoji and is what the write path uses.

`delivery_plan(decision, emoji_kind)` returns `{ activity_type: 'EmojiReact' | 'Like' | nil, audience: :author_inbox | :followers_and_mentions | :none }`. The write services (`EmojiReactionService`, `UnEmojiReactionService`, and `CustomEmojiDistributionWorker` for the per-Node split) take the activity type from this one function, so create and undo cannot disagree (F1) and fan-out and single delivery cannot disagree (F4). The kmyblue rule becomes data in the Node snapshot (`mechanism_override: like_fallback`) and not code in a service.

Entry points: `Resolver.call(input)` and `Resolver.call_many(inputs)` (same result as mapping `call`, no per-item I/O). The Node rule that turns a Node row into a snapshot (`NodeCapability.snapshot(row)`) also lives here and is the only place that reads `info['emoji_reaction_type']`. It treats a missing key as `unknown`, not as `custom` (answers F3 and F4 with one rule).

#### 5.1.1 Node snapshot normalization

`Node#info` is heterogeneous. `UpdateNodeService` writes booleans for most keys, but `process_software_specific_override` writes the string `'none'` for `favourite`, `reply`, `reblog`, `reference` (and `'none'` and `0` for the emoji keys) for `birdsitelive`, and the `FEATURES` defaults, `Node#features`, and `REST::NodeSerializer` use `true`, `:public`, and `nil` for the same keys. A check such as `favourite == false` is therefore wrong. The snapshot is the only place that reads raw values, and it maps them as follows. Anything not listed maps to `unknown` or `null`, never to a permissive value.

| Raw `info` value | Snapshot field | Normalized value |
|---|---|---|
| `emoji_reaction_type`: `'custom'`, `'unicode'`, `'none'` | `emoji_reaction_type` | the same string |
| `emoji_reaction_type`: key absent, `nil`, any other value or type | `emoji_reaction_type` | `unknown` (not the `FEATURES` default `'custom'`, F3) |
| `favourite`: `true`, `'public'`, `'true'` | `like_delivery` | `accepts` |
| `favourite`: `'none'` | `like_delivery` | `rejects` (the `birdsitelive` rule) |
| `favourite`: `false` | `like_delivery` | `unknown`. Inference sets `false` for the `misskey` upstream, which has no favourite concept but does receive a `Like` as a reaction. It is not a rejection of Like. |
| `favourite`: key absent, `nil`, any other value | `like_delivery` | `unknown` |
| `emoji_reaction_max`: Integer greater than 0 | `max_per_account` | that Integer |
| `emoji_reaction_max`: `0` with `emoji_reaction_type` of `none` | `max_per_account` | `0` |
| `emoji_reaction_max`: `0` with any other type, negative, non-Integer, absent | `max_per_account` | `null` (a zero cap with a reaction-capable type is an inconsistent override; no source defines it) |
| `nodes.status` | `reachability` | `gone` for `gone`; `up` for `up`; `unknown` for the other values (`error`, `busy`, `reject`, `not_found`, `no_address` are transient or unrelated to reactions) |
| no `nodes` row | all of the above | `unknown`, `unknown`, `null`, `unknown` |

`software == 'kmyblue'` sets `mechanism_override: like_fallback`, so the one-off rule moves from `EmojiReactionService` into data (F1).

Normalization is a pure function over the selected columns and is covered by a table-driven spec that includes each raw shape in the table, including the `birdsitelive` override as produced by `UpdateNodeService`.

#### 5.1.2 Decision order

Evaluated in this order, first match wins. Steps 1 to 3 are shared by both kinds and step 4 is evaluated once per kind. This is the priority used by the decision table in section 7.

1. `disabled`: viewer `disable_reactions`; external content; `blocked_by_author`; `viewer_blocks_author`; `domain_rejected`; `status_override` forbids. (Status not visible is answered earlier by `show?`.)
2. `unsupported` (per kind): the author is not ActivityPub; or `reachability` is `gone`; or the kind has no native path and Like delivery is rejected, that is `emoji_reaction_type == 'none'` and `like_delivery == 'rejects'`. A kind whose native path is missing for another reason (a `unicode`-only Node and a custom emoji) is not unsupported by itself; it falls to a mechanism in step 4.
3. `limit_reached`: `remaining == 0`.
4. Mechanism, then consent (per kind). The mechanism is `native` when the normalized type covers the kind (`custom` covers both kinds, `unicode` covers `unicode` only) and there is no `mechanism_override`. It is `like_fallback` when native does not apply and `like_delivery == 'accepts'`. It is `unknown` when the type is `unknown`, or when native does not apply and `like_delivery == 'unknown'`. `native` is `allowed`. `like_fallback` and `unknown` consult the policy: `allow` is `allowed` for `like_fallback` and `unknown` for an unknown mechanism (section 3.1), `ask` is `confirm`, `deny` is `disabled` with `fallback_denied` (or `capability_unknown_denied` when the mechanism is unknown).

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

Exposure: InitialState metadata for the WebUI, and `GET /api/v1/fedibird/preferences` as a read-only key. Exposing it in the Fedibird preferences API is not just a serializer change. The Settings Service is closed over explicit lists, and each of these has to change in the same PR:

- `UserPreferences::Reader::KEYS` and `STORAGE_KEYS` (`UserPreferences::Schema.validate_structure!` raises if the registry and these lists differ), plus a `UserPreferences::Definition` entry with `write_policy: :read_only`.
- `UserPreferences::Schema::CATEGORIES` (`posting`, `translation`, `appearance` today) needs a new category such as `safety`, because `validate_definition` rejects an unknown category.
- The schema and preference documents and their conformance specs, and the catalog entry above.

The key must not be added to `UserPreferences::WriteContract::KEYS`. `Writer` and `PatchDocument` accept only keys in that list (`unsupported preference key` otherwise), so a Reader and Schema key that is absent from `WriteContract::KEYS` cannot be edited through `PATCH /api/v1/fedibird/preferences` or `reset`. No stored key is `read_only` today (the only `read_only` definition is the derived `preferred_posting_language`), so P1 must add a spec that proves the write and reset paths reject this key before the key ships, and that proves `write_policy: :read_only` for a stored key does not by itself block a write. Changing the policy through the API stays out of scope for P1 and P2: D2 keeps high-risk keys off the general write port, and the Rails safety preferences form is the only writer. Third-party clients can see the value and the per-status decision, but cannot change it.

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

1. The client calls the existing `PUT` without consent. If the decision for the emoji being written is `confirm`, the server answers `409` with `error_code: fallback_confirmation_required`, `details` (mechanism, effects) and `confirmation_token`.
2. The client shows the prompt, and on acceptance repeats the same `PUT` with `fallback_confirmation=<token>`.
3. The token is signed with `ActiveSupport::MessageVerifier`, purpose `emoji_reaction_fallback`, and binds all of: `user_id`; the canonical status id (`status.proper.id`, section 8.3); the exact emoji identity; the mechanism; the target domain; a digest of the normalized Node snapshot (section 5.1.1) and of the policy value that produced the decision; and an expiry of a few minutes.
4. The emoji identity is the unicode string exactly as stored in `EmojiReaction#name` for a unicode emoji. For a custom emoji it is the resolved `custom_emoji_id` (the shortcode and domain after `domain == local_domain` is normalized to no domain), not the shortcode alone. A token for another emoji of the same kind is therefore invalid.
5. Redemption re-decides. Before any write, the server recomputes the decision for this status and this emoji from current state and does not trust anything in the token except the binding. If the recomputed decision is still `confirm` with the same mechanism, effects, and snapshot digest, the write proceeds. If the policy is now `deny`, the answer is `403 fallback_denied`. If the Node is now native, the token is ignored and the write proceeds as native. If the limit is now reached or the Node is now unsupported, the answer is `422`. If the mechanism or snapshot digest changed in any other way, or the token is expired or does not match the request, the answer is `409 fallback_confirmation_invalid` with a fresh token. A token that was issued under `ask` does not survive a change to `deny`.
6. A token is single use: redemption records the token id in Redis with `SET NX` and a TTL equal to its lifetime, so a replay after the reaction is removed needs a new prompt. The reaction itself stays idempotent (section 8.3), so a replayed request for a reaction that already exists is a no-op and is not a consent issue.

What this guarantees and what it does not: the server never delivers a fallback Like for `ask` without a token that the server issued for that exact status, emoji, mechanism and state, and `deny` can never be bypassed. A client that retries automatically without asking the user still gets through, because the server cannot see the user. That is the same trust boundary as any OAuth client acting for a user, and it is why `deny` (hard, server-enforced) exists next to `ask` (a protocol handshake). The WebUI is the only client that this design requires to show a dialog.

Set aside: a plain boolean parameter `confirm_fallback=true` (a third-party client can send it on every request, so `ask` degenerates to `allow` and the user-facing meaning is lost); a stored "consent per domain" row (new data and an unclear lifecycle); trusting the client-side policy value (stale, forgeable).

### 6.4 `deny`, removal, and delivery identity

`deny` applies to the write service (not only the UI). It refuses adding a reaction that would be delivered as a fallback `Like`. It never blocks removal, and never blocks a native reaction.

#### 6.4.1 Why a `delivery` column on `emoji_reactions` is not enough

Today the identity of a delivered activity is the reaction row. `ActivityPub::EmojiReactionSerializer#id` is `<actor>#emoji_reactions/<row id>`, and `ActivityPub::UndoEmojiReactionSerializer` wraps that same activity as its `object` and has its own id `<actor>#emoji_reactions/<row id>/undo`. The service serializes the payload when it enqueues the job, from the row it is about to delete. This works only while exactly one activity is sent per row.

A "send the first Like only, and send an Undo when the last reaction goes" rule (C2) breaks that. If the first row is removed first, no activity is sent, and the row that is removed last has a different id, so an `Undo` built from it does not name the Like that was actually sent. A server that matches an `Undo` by activity id (not by actor and object) would ignore it. A nullable `delivery` string on the row records the mechanism of each reaction, which fixes undo type symmetry (C5), but it cannot record which one activity was sent for a group of reactions. Aggregation therefore needs the identity of the sent Like stored independently of any reaction row.

#### 6.4.2 Proposed storage (not decided, blocking prerequisite for Like aggregation)

- `emoji_reactions.delivery_mechanism` (nullable string: `native`, `like_fallback`, `local_only`; `NULL` for rows that predate the column). Written at create. Read by `UnEmojiReactionService` to choose the Undo type, so create and undo cannot diverge when the Node changes in between (C5). `local_only` covers a silenced author and a non-ActivityPub author (F13).
- `emoji_reaction_deliveries` (new table): `id`, `account_id`, `status_id` (canonical, section 8.3), `mechanism` (`like_fallback`), `activity_uri` (the id of the Like that was sent), `activity_json` (the serialized Like, so an Undo can be built after the originating row is gone), `state` (`active`, `undoing`, `undone`), timestamps. A unique index on `(account_id, status_id)` where `state = 'active'`.
- `emoji_reactions.delivery_id` (nullable foreign key to the table above, `ON DELETE SET NULL`). Several reaction rows of one account on one status can share one delivery.

Rules:

1. First fallback reaction. In one transaction, create the active delivery with `activity_uri` equal to the id the Like would have had today (`#emoji_reactions/<row id>`, so the first Like on the wire is unchanged), create the row with `delivery_id`, and enqueue the `Like` after commit. Only the transaction that created the delivery enqueues.
2. Later fallback reactions by the same account on the same status. The row links to the existing active delivery and no activity is sent. This is the "remote cannot count more than one" behavior of C2, made explicit.
3. Removal. In one transaction lock the delivery row, delete the reaction row, and count the rows still linked. If rows remain, send nothing. If none remain, set `state = 'undoing'` and enqueue an `Undo` built from `delivery.activity_json`, after commit, so removing the first row first still undoes the correct Like.
4. Favourite coexistence. The remote server has one favourite slot per actor and status, and both a local `Favourite` and an active fallback delivery use it. The slot has two possible owners, and an `Undo(Like)` is sent only when the last owner leaves. In rule 3, if the viewer still has a local `Favourite` on the status, no Undo is sent and the delivery is set to `undone` with a note that the favourite kept the slot. The reverse also has to hold: when the viewer removes the favourite while an active delivery exists, `UnfavouriteService` must not send its `Undo(Like)`. That is a change to the favourite services, which are outside the emoji reaction code, and is part of the prerequisite.
5. Retries and idempotency. Payloads are serialized at enqueue time and stored with the delivery, so a Sidekiq retry sends the same activity id, which a remote server can deduplicate. A repeated `PUT` for a reaction that already exists must not enqueue anything (section 8.3).
6. Race between Undo and a new Like. After `undoing`, a new fallback reaction creates a new active delivery with a new `activity_uri`. Sidekiq does not order the two jobs, so on a server that deduplicates by actor the new `Like` can be processed first and the old `Undo` then removes the favourite although a reaction exists. This is a known gap. A per-account-and-status ordering of the two jobs (or a short delay on the new Like) is a possible fix and is Q18.
7. Legacy rows (`delivery_mechanism IS NULL`, `delivery_id IS NULL`). They have already sent one `Like` each, with the row id. They are not folded into a delivery and are undone one by one with the shared `delivery_plan`, as today. No backfill is needed.
8. Fan-out for a local author (`CustomEmojiDistributionWorker`) keeps one `Like` per reaction row for followers on fallback Nodes. Aggregating there is not designed in this note (Q18).

Whether aggregation is wanted at all is Q4. If it is not, this storage is not needed for P1b, and only `delivery_mechanism` is.

## 7. Decision table

Rows are evaluated in this order. The mechanism column is the mechanism of the kind of the emoji being written, so a status can follow different rows for a unicode emoji and a custom emoji (rows M1 and M2). `remaining` is greater than 0 unless stated. `current` is the viewer's reaction count. "Write" is the result of the REST write with the policy and token shown.

Hard blocks and unsupported (policy independent):

| # | Mechanism | Policy | Other state | `availability` | `reason` | Write |
|---|---|---|---|---|---|---|
| H1 | any | any | `disable_reactions = true` | `disabled` | `viewer_reactions_disabled` | 403 |
| H2 | any | any | author blocks viewer, or viewer blocks author or domain, or domain rejected | `disabled` | `blocked_by_author` / `domain_blocked` | 404 (not visible) or 403 |
| H3 | any | any | external content | `disabled` | `external_content` | 422 (existing guard) |
| H4 | `none` | any | normalized `emoji_reaction_type` is `none` and `like_delivery` is `rejects` (raw `favourite: 'none'`, as `birdsitelive` sets it, section 5.1.1) | `unsupported` | `node_unsupported` | 422 |
| H5 | `none` or `unknown` | per policy | normalized `emoji_reaction_type` is `none` and `like_delivery` is `unknown` (raw `favourite` `false`, absent, or other) | not unsupported. Follows `unknown` rows U1 to U4. | | |

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


Mixed kinds on one Node (normalized type `unicode`, `like_delivery` `accepts`). The aggregate is the best of the two kind rows:

| # | Emoji written | Policy | Kind decision | Write |
|---|---|---|---|---|
| M1 | unicode | any | `native`, row N1 or N2 | 200 or 422 |
| M2 | custom | `allow` | `like_fallback`, row F1 | 200 |
| M3 | custom | `ask` | `like_fallback`, row F2 | 409 then 200 |
| M4 | custom | `deny` | `like_fallback`, row F3 | 403 `fallback_denied`; the unicode entry stays usable |

Whether a custom emoji on a `unicode`-only Node really is `like_fallback` and not `unsupported` is unverified (Q7). The rows follow the rule in section 5.1.2 until a fixture says otherwise.

Removal (independent of everything above):

| # | State | `can_remove` | Remove result |
|---|---|---|---|
| R1 | viewer has at least one row on the canonical status (`status.proper`), any policy, `disable_reactions` true or false, any Node state | true | 200, undo delivered per `delivery_mechanism` (and the delivery identity rules of section 6.4 if adopted), or the shared plan for legacy rows |
| R2 | no rows | false | 200 no-op (existing) |

Counterexamples the table has to survive:

- C1, add then policy change: the viewer reacted under `allow`, then set `deny`. The row stays, `can_remove` is true, removal works, and a later add is refused. Undo must send the same type that create sent.
- C2, many Likes, one favourite: a Like-fallback server that deduplicates favourites keeps a single favourite for the viewer on that status however many reactions were sent. Upstream Mastodon does this for `Like`. This is not verified against any implementation in this repository and must be confirmed with fixtures in P1. The 2nd to Nth reaction therefore delivers nothing the author can see, and an `Undo(Like)` for any one of them removes the single favourite while the viewer still has other reactions. If a design sends only the first `Like`, it must also keep the identity of that one activity, because the first row may be removed first (section 6.4).
- C3, real favourite plus fallback: the viewer favourited the status and then reacted through the fallback. On a deduplicating server, undoing the reaction removes the favourite. Mitigation to evaluate: the favourite slot has two owners, the `Favourite` and the active fallback delivery, and an `Undo(Like)` is sent only when the last owner goes (section 6.4.2, rule 4). That needs a change in the favourite services too. `effects: ["remote_favourite"]` exists so the confirmation text can warn about this.
- C4, native claimed, server rejects: a `declared` capability can be wrong or can change. A native `EmojiReact` can be dropped by the author's server and the viewer's local row still exists. `can_add: true` is a statement about this server's acceptance, not about the author's server (section 8).
- C5, undo after capability change: the Node was `custom` at create and `none` at undo, or the reverse. Without `delivery_mechanism` on the row, the undo type is chosen from the new state.
- C6, concurrent adds: two requests both see `remaining = 1`. The resolver cannot prevent that; the write must still enforce the cap (section 8, race).
- C7, reblog: the viewer reacts on a boost. The row is for the original and the author is the original's author. Every step (resolver, add, delete, limit, consent token) must use the canonical status id, not only the resolver (section 8.3). A decision that used the booster's Node would mis-decide.
- C8, first row removed first: the viewer has reactions A, B, C on a fallback Node, only A's `Like` was sent, and removes A then C then B. An `Undo` built from B's row id does not name A's `Like`. The delivery identity of section 6.4 exists for this case.

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

### 8.3 Canonical status and idempotent retry

The unit of every reaction operation is the canonical status, `status.proper` (the original for a boost, the status itself otherwise). The resolver alone using it is not enough (F15). The following all use the canonical id and are covered by the same tests:

- Authorization stays on the status in the URL (`authorize @status, :show?`). It is the status the viewer can see. After it passes, the controller resolves `canonical = @status.proper` once and passes `canonical` to the service, the resolver, and the consent token. The response keeps rendering the status in the URL, so existing clients see the same shape.
- `EmojiReactionService` looks up, creates, counts, and applies the limit with `canonical.id`. `UnEmojiReactionService` filters with the canonical status, so a delete through a boost removes the row that the add through that boost created.
- The consent token binds `canonical.id` (section 6.3), and a token issued for the original is valid for the boost and the reverse.
- The unique index, `EmojiReaction#before_validation`, and the validator already operate on the original, so these changes make the service agree with them.

A repeated `PUT` for an existing reaction is a no-op. It returns the current status, does not call `NotifyService`, does not enqueue a delivery or distribution, and does not bump potential friendship (F16). Notification, delivery, and friendship run only when `newly_reacted` is true. A lost create race (`RecordNotUnique`) is a no-op for the loser in the same way. If P1b adopts the delivery identity of section 6.4, only the transaction that created the delivery enqueues the `Like`.

## 9. Backwards compatibility, cache, ETag, and invalidation

Compatibility:

- Additive only. No existing field is removed or retyped. `emoji_reactions`, `emoji_reactioned`, `/api/v1/instance` `max_reactions_per_account` stay as they are.
- A client that ignores `interaction_capabilities` behaves as today. A client that reads it must treat an absent field as "unknown" and keep its current local logic.
- Existing write requests keep working under policy `allow`. They only meet `409` after the default has been flipped for an account (section 6.2).
- The WebUI keeps `reactionLimitReached` until P2 replaces it for statuses that carry the field.

Cache and ETag:

- REST: no server-side cache of decisions. They are computed on read from preloaded data (section 5.2), so they cannot be stale on the server side. Authenticated REST responses are not publicly cacheable, and `cache_if_unauthenticated!` only applies without a user. The field is absent when `current_user` is nil, so a cached public response cannot leak a viewer decision.
- Streaming: the viewer-specific decision is never added to a shared payload. The anonymous renderers (`FanOutOnWriteService`) emit no field because `current_user` is nil. Per-account payloads (`PushUpdateWorker`, `PublishStatusUpdateWorker`) would carry it. What the WebUI does for statuses that arrive without it is in section 9.1.
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

### 9.1 Live statuses in the WebUI (P2)

The home, list, public, and tag streams carry the shared anonymous payload (section 1.8). A status that arrives live therefore has no `interaction_capabilities`. If nothing is done, the WebUI uses the legacy local-limit logic (F11) for every live status, which is exactly today's behavior and is safe, but it loses the decision for the statuses the user sees first. P2 must choose one of these, with the budgets given, and must not make the baseline worse than today.

| Option | What it does | Cost | Verdict |
|---|---|---|---|
| A. Lazy fetch on interaction | When the user opens the reaction picker or reaction chips for a status that has no fresh decision, fetch that status (`GET /api/v1/statuses/:id`, or a batch form for the visible statuses of the thread) and merge the decision. Until it arrives, the picker behaves as today. | One request per picker open, about 1 KB. Zero standing cost and no change to streaming. | Baseline. Recommended for P2. |
| B. Viewer-independent part in the shared payload | Add a compact viewer-independent object to the anonymous payload: the author's per-kind mechanism and `target_max` (about 80 bytes per status). The WebUI combines it with what it already holds: the policy (InitialState), the local cap, and its own count from `emoji_reactions` `me`. | One Node lookup per status in the fan-out renderer (memoized per domain for the life of the worker batch), about 80 bytes per streamed status. The client then re-implements the combination step, so the drift risk is real, and this option needs the measurements in section 10 before it is adopted. | Optional follow-up, only if A proves too slow. Not in P2. |
| C. Batch backfill of every streamed status | After a stream batch, the client requests decisions for the statuses that arrived. | A request per streamed batch, scaling with timeline speed. | Rejected. |

Budgets for A: at most one request per picker open, no request for statuses that are not interacted with, and no more than 50 ids in a batch form. Budgets for B: at most 100 bytes per status on the shared payload and at most one additional query per fan-out batch, which is checked against the fan-out latency measurement.

Store rules, which apply to every option:

1. The status importer must not remove or replace a stored `interaction_capabilities` when an incoming status does not contain it. It replaces it only with an incoming value.
2. The client keeps the time at which it received the decision. A decision older than five minutes is treated as stale and is refetched when the picker opens (option A). A stale decision is never used to enable an entry that the legacy logic would disable.
3. The client discards or refetches a stored decision after its own reaction add or remove (the write response replaces it), after a settings change that it knows about, and after any error response whose `details` carry a decision.
4. A stored decision is never used for a safety decision. The write is always re-decided on the server.

How `reducers/statuses.js` and the status importer merge an incoming status with a stored one is not read in this inventory. P2 starts by reading it and by adding a regression test for rule 1 (Q10).

Failure of the resolver: a resolver exception or missing preload must not break the status. The serializer omits `interaction_capabilities` (client falls back to current logic) and counts the failure. The write path fails closed for the decision it cannot compute only when the policy is `deny` or `ask`; with `allow` it proceeds as today. This keeps `allow` behavior identical to the current code during rollout.

## 10. Tests and measurements required before enabling status-inline fields

Tests (all required before the flag in section 11 is turned on in P2):

1. Resolver unit tests: every row of sections 4 and 7 as a table-driven spec, including the priority order (`disable_reactions` over `unsupported` over `limit_reached` over policy), the `availability` to booleans mapping in section 3.1, the aggregate rule over two kinds, and the mixed-kind rows M1 to M4 (unicode usable while a custom emoji is `deny` or `confirm`).
1a. Per-emoji contract test: for a generated status and each emoji kind, the write-time decision for an emoji equals `kinds[kind]` of the summary except for the emoji-specific reasons listed in section 3.1.
2. Node snapshot tests: every raw shape in the table of section 5.1.1: missing row, `nodeinfo` missing, key absent, `nil`, `true`, `false`, `'public'`, `'none'`, `0`, a negative or non-Integer max, `unicode`, `custom`, `birdsitelive` as `UpdateNodeService` produces it (`favourite: 'none'`, `emoji_reaction_type: 'none'`, `emoji_reaction_max: 0`), the `misskey` family with `favourite: false` (not `rejects`), `kmyblue`, override winning, `gone`. Assert that an absent key is `unknown`, not `custom`.
3. Delivery-plan parity tests: for every Node snapshot and emoji kind, `EmojiReactionService`, `UnEmojiReactionService`, and `CustomEmojiDistributionWorker` pick the same activity type for the same reaction (F1, F4). Includes the create then undo case with a Node change between (C5).
4. Contract test between resolver and write: for every generated input where the resolver says `can_add && !requires_confirmation`, the service creates the row, and where it says `deny` or `unsupported`, no delivery job is enqueued.
5. Query-count tests: a page of 40 statuses from 40 different domains, and from 1 domain, with and without a reblog, adds at most the budgeted queries (section 5.2) and the count does not grow with N or D. Anonymous requests add none.
6. Serializer tests: field absent when `current_user` is nil, when the flag is off, and in the shared streaming payload (`FanOutOnWriteService` anonymous payload); present and correct for `PushUpdateWorker`.
7. Controller or request specs for every error row in section 8.1, including consent token binding (wrong status, wrong user, wrong emoji of the same kind, a different custom emoji, expired, replay after redemption, token issued under `ask` redeemed after the policy became `deny`, after the Node became native, and after the Node snapshot changed) and that removal works under `deny` and `disable_reactions`.
7a. Canonical status specs (section 8.3): add, delete, limit, and consent token through a boost wrapper act on the original and agree with the same operations through the original; a repeated `PUT` through a wrapper is a no-op and returns neither 422 nor 404.
7b. Idempotency specs: a repeated `PUT` for an existing reaction does not call `NotifyService`, does not enqueue `DeliveryWorker` or `CustomEmojiDistributionWorker`, and does not call `PotentialFriendshipTracker`; a lost `RecordNotUnique` race behaves the same.
7c. Delivery identity specs, only if section 6.4.2 is adopted: first reaction sends one `Like` with the same id as today; later reactions send nothing; removing the first row first sends nothing and removing the last sends an `Undo` that names the first `Like`; a local `Favourite` suppresses the Undo and the reverse; a Sidekiq retry sends the same activity id; legacy rows keep the per-row behavior; the Undo and new-Like race (6.4.2 rule 6) is characterized, not hidden.
8. Concurrency spec for the cap (two parallel writes at `remaining = 1`, one succeeds).
9. Policy and settings specs: settings catalog regeneration and check scripts, preferences form, `UserSettingsDecorator` allow-list, default and `grandfathered` resolution. For the Settings Service: the key is in `Reader::KEYS`, `STORAGE_KEYS`, `Definition`, and a new `Schema::CATEGORIES` category so `validate_structure!` passes; it is absent from `WriteContract::KEYS`; `PATCH /api/v1/fedibird/preferences` and `preferences/reset` reject it; the schema endpoint reports it as read-only.
9a. WebUI specs (P2): the status importer keeps a stored `interaction_capabilities` when an incoming status lacks it and replaces it when present; a decision older than five minutes is refetched on picker open and never enables an entry the legacy logic disables.
10. Compatibility specs: an old-style client request (no token) under policy `allow` is unchanged byte for byte in status code and in existing fields.

Measurements (staging with production-shaped data, before and after, flag on and off):

| Metric | Budget (proposal) |
|---|---|
| Extra queries per page | at most 1, independent of N and D |
| Added p95 latency of `GET /api/v1/timelines/home` (40 statuses) | at most 5 percent |
| Payload growth per status | at most 600 bytes uncompressed (the per-kind objects of section 3.1 are about 520 bytes; the compact form without `kinds` is an optimization to evaluate if this is exceeded) |
| Serialization allocations per page | measured, no regression above 5 percent |
| Shadow-mode divergence: legacy sender activity type versus resolver `delivery_plan` over a representative window of real writes | reported by Node software, every divergence either explained by one of F1 to F4 or fixed before enforcement |
| Node coverage: share of author domains with a known (non-`unknown`) snapshot among statuses served | reported; this decides how often `unknown` reaches users |

## 11. Phasing, rollout and rollback

Each phase is its own PR with its own flag, and none depends on a data backfill. The recommended order differs from the P1, P2, P3 numbering in the issue for safety reasons given after the table.

| Phase | Scope | Flag and rollout | Rollback |
|---|---|---|---|
| P1a | Resolver, Node snapshot, delivery plan; shadow mode only. The services still decide as today; the resolver runs beside them and logs divergence. No API, setting, schema, or UI change. | site setting `emoji_reaction_resolver_shadow` (off by default, sampled) | turn the flag off; no persisted state |
| P1b-1 | Fallback policy setting (high-risk, catalog entry, safety form, `allow` effective default), write gate in `EmojiReactionService`, consent handshake, error codes, canonical-status fixes and idempotent retry (section 8.3, F15, F16), shared delivery plan for create, undo, and fan-out (each F1 to F4 fix behind its own sub-flag), `emoji_reactions.delivery_mechanism` column (nullable, additive). One `Like` per row stays as today; no aggregation. | `emoji_reaction_resolver_enforce`. Enable for staff accounts, then a percentage of accounts, then all. Default stays `allow`. | turn the flag off to restore the legacy sender and the controller-only checks. The `delivery_mechanism` column is nullable and ignored; leaving it does no harm. The idempotency and canonical-id fixes are behavior fixes and have their own sub-flags. |
| P1b-2 | Like aggregation: `emoji_reaction_deliveries`, `delivery_id`, last-remove Undo, favourite slot sharing (section 6.4.2). **Blocked.** It must not start until Q4 is decided, the delivery identity design is reviewed, and the dedup and Undo-matching behavior of the target server families is confirmed by fixtures (Q4, Q17). | `emoji_reaction_like_aggregation` | turn the flag off: rows with a `delivery_id` are undone one by one as legacy rows by the shared plan; the table is ignored |
| P2 | `interaction_capabilities.emoji_reaction` on REST statuses for authenticated viewers, `fallback_policy` in preferences (read-only), WebUI: disable unsupported and exhausted controls from the decision, confirmation dialog for `confirm`, error code handling. Streaming shared payloads unchanged. | `emoji_reaction_interaction_capabilities` (site), then per account. | turn the flag off: the field disappears and the WebUI falls back to `reactionLimitReached`. |
| P1c | Flip the default policy to `ask` for new accounts, with grandfathering (section 6.2). Only after P2's dialog is live in the WebUI and the compatibility measurement shows no unexpected `409`s. | cutover timestamp setting | set the cutover to the past or the default back to `allow`; stored user values are untouched |
| P3 | Node capability storage with provenance, `GET`/batch Node capability API, admin visibility of `declared`/`inferred`/`overridden`, and stop reading `FEATURES[:emoji_reaction_max]` as a remote value (F5). Replaces the unused `REST::NodeSerializer` fields. | `node_capabilities_api` | route off; additive storage stays unused |

Why not strictly P1, P2, P3: the Like aggregation and its Undo identity are separated from the rest of P1b (P1b-2) because they are the only part with an unresolved identity problem and they change what remote servers see; policy enforcement, consent, and the id and idempotency fixes do not depend on it. Shadow mode (P1a) is a pure measurement and must come first; the default flip must come after the dialog (P1c after P2), otherwise `ask` blocks users who have no way to answer; Node provenance (P3) improves decisions but does not block P1b and P2, which can run on the coarse snapshot (`unknown` is safe), so P3 can ship last. Streaming never carries the field in any phase.

P1a may start as soon as this document is accepted. P1b-1 starts only after the review items on the consent token, the canonical status, the Node normalization, and the per-kind schema are accepted. P1b-2 stays blocked as stated above.

Exit criteria to move from shadow to enforcement: divergence explained; the tests in section 10 green; the query and latency budgets met. Exit criteria for P2 (using the lazy fetch of section 9.1, option A): budgets met with the flag on for staff accounts for a measurement window, no increase in write error rate, `unknown` share reported.

## 12. Open design questions

These are not decided by this document.

| # | Question | Recommendation, if any |
|---|---|---|
| Q1 | Default policy and migration for existing users (section 6.2). | Effective `allow` first; `ask` for new accounts after cutover; grandfather existing accounts. Needs an owner decision. |
| Q2 | Final wire names: `interaction_capabilities` as a top-level status key, `emoji_reaction_fallback_policy`, error codes, `mechanism` and the per-kind object shape of `kinds`, `target_limit_known`. | As written; confirm with client authors before freezing. |
| Q3 | What to send to an `unknown` Node under `allow`: `EmojiReact` (today's behavior for a Node row with empty `info`) or `Like` (today's behavior for a missing row)? | `Like` with the fallback effects, since `unknown` is never native. This changes behavior for NodeInfo-less servers; it needs shadow-mode data. |
| Q4 | Under Like fallback, should the 2nd to Nth reaction on one status send an additional `Like`? Aggregation (one `Like`, one `Undo` at the last removal) cannot be built on the reaction row id alone (F17, C8), so it needs the delivery identity of section 6.4.2. | Undecided. Aggregation is the better remote behavior only if the targets deduplicate favourites, and that is unverified (the note cites upstream Mastodon from memory). Until Q4 is decided and fixtures confirm the target behavior, P1b-2 is blocked and P1b-1 keeps one `Like` per row. |
| Q5 | Is a `delivery_mechanism` column on `emoji_reactions` acceptable, or should undo keep deriving from the current Node? Separately, is the `emoji_reaction_deliveries` table acceptable if Q4 chooses aggregation? | Add `delivery_mechanism` (nullable, additive); without it C5 cannot be fixed. The table is only for aggregation and depends on Q4. |
| Q6 | `409` versus `428` for the consent handshake. | `409`. |
| Q7 | Is a custom emoji on a `unicode`-only Node `like_fallback` or `unsupported`? Today the service sends `EmojiReact` with `:name:` content. The rule in section 5.1.2 treats it as `like_fallback` when `like_delivery` is `accepts`, as a placeholder. | Not decided; needs a fixture against a unicode-only server. |
| Q8 | Turning the silent no-op for foreign custom emoji (F10) into `422`. It is a visible API change. | Do it in P1b behind its own sub-flag. |
| Q9 | Expose the per-status distinct cap (20) and the distinct count? It needs aggregate data and is a display cap, not a write cap. | Leave out of v1. |
| Q10 | How do `reducers/statuses.js` and the importer merge a status that lacks a field present in the store (shared streaming payloads)? Not read in this inventory. Section 9.1 requires that an absent field never replaces a stored one. | Check at the start of P2; add a regression test. |
| Q11 | Per-status "disallow reactions": where is it stored and who sets it (author, moderator)? Should it federate? No storage or product definition exists. | Reserve `status_disallowed`; no field, no schema in P1 to P3. |
| Q12 | Inbound reactions to a local status: should the viewer setting, the per-status override, and the fallback policy apply? Today none apply (section 1.1). | Per-status override and `disable_reactions` of the author should apply to inbound; the fallback policy is about outgoing delivery only. Needs a product decision. |
| Q13 | Should `reachability` consider `DeliveryFailureTracker` (Redis) per domain? | Not in v1; use `Node.status` only; revisit with a batched lookup in P3. |
| Q14 | `kmyblue` becomes data (`mechanism_override`) in the Node snapshot. Where does the admin edit it: `info_override` or a new key? | `info_override`, documented in P3. |
| Q15 | The inbound limit for remote reactors is the fixed 20; should it follow the author's local cap for local authors? | Out of scope; recorded because it is a different limit from the viewer decision. |
| Q16 | Should there be a per-emoji dry-run check (for example a decision endpoint for one status and emoji)? Without it the first write attempt, with its `409` or error body, is the only per-emoji check (section 3.1). | Not in v1. Revisit if clients need to grey out individual custom emoji before the first write. |
| Q17 | Does each target family match an `Undo` by actor and object, or by activity id? This decides whether the first `Like`'s id matters, and whether a Node snapshot needs an `undo_match` field (`by_actor`, `by_id`, `unknown`). | Verify with fixtures per family (Mastodon, Pleroma-family, Misskey-family, GoToSocial) before P1b-2. |
| Q18 | Ordering of an `Undo` followed by a new `Like` for the same account and status (6.4.2 rule 6), and whether fan-out for a local author should aggregate (rule 8). | Not designed. Per-account-and-status job ordering or a short delay on the new `Like` are the candidates. |

## 13. Non-goals of this document

No P1 work starts from this PR. This change does not touch `app/`, `config/`, `db/`, `spec/`, `script/`, or `streaming/`. It does not edit `docs/settings_service/catalog.yml`, regenerate any generated file, change feature flags, create a migration, or deploy.
