# Fedibird capability discovery (P1)

Tracking: [#725](https://github.com/fedibird/mastodon/issues/725) /
[#726](https://github.com/fedibird/mastodon/issues/726).

This is an **additive, software-wide, self-declared implementation catalog**.
It is not an OAuth authorization decision, proof of a remote actor's
features, or a promise that an action is currently allowed on a target.

## Public interfaces and compatibility

| Endpoint | New/retained data | Audience |
| --- | --- | --- |
| `GET /api/v1/instance` | Retains the original `fedibird_capabilities` array only | Legacy REST clients |
| `GET /api/v2/instance` | Original array plus new `fedibird` object | REST clients |
| `GET /nodeinfo/2.0` | `metadata.fedibird` with AP-only hints | Federation/NodeInfo consumers |

`/.well-known/nodeinfo` still discovers NodeInfo schema 2.0.
Mastodon compatibility remains **4.2.13**; do not add
`api_versions.mastodon` until the promised upstream API version is
actually implemented. [PR #255](https://github.com/fedibird/mastodon/pull/255)
intentionally omitted that field. The older `feature_quote` and
`fedibird_capabilities` fields are unchanged.

## Example: v2 instance fragment

```json
{
  "fedibird": {
    "schema_version": 1,
    "rest": {
      "supported": [
        "emoji_reactions",
        "status_references",
        "status_expiration",
        "status_searchability",
        "extended_visibilities",
        "filters_v2",
        "group_directory",
        "timeline_seek",
        "reading_bookmarks",
        "preferences_schema",
        "status_translation"
      ],
      "translation": {
        "instance_enabled": false,
        "viewer_scoped": true
      }
    },
    "activitypub": {
      "supported": [
        "emoji_react",
        "note_references",
        "legacy_quote_uri",
        "searchable_by",
        "group_actor"
      ]
    }
  }
}
```

The fragment omits normal Instance fields and the legacy capability array.
`supported` means the code path exists. It does **not** mean the
deployment has enabled it, the calling token has suitable scopes, or a
given user/target is eligible. Follow the relevant endpoint's auth,
feature-gate, and permission rules.

`translation.instance_enabled` uses
`TranslationService.configured?` (instance provider only).
`viewer_scoped: true` indicates that a user may have personal DeepL
credentials; it does not claim the current user has one, can translate
private statuses, or will get a working provider. The authenticated
`GET /api/v1/fedibird/translation_languages` reflects the user's
effective selection. `GET /api/v1/instance/translation_languages` is
still instance scoped.

The REST hints correspond to implemented endpoints or serializers:
`/api/v1/statuses/:id/emoji_reactions`,
`/api/v1/statuses/:id/referred_by`,
`/api/v1/statuses/:id/expire`,
`/api/v2/filters`,
`/api/v1/group_directory`,
`/api/v1/timelines/seek`,
`/api/v1/fedibird/reading_bookmarks`, and
`/api/v1/fedibird/preferences/schema`. Extension-specific visibility
values are not the same as the standard Mastodon visibility contract.
Private external bridge projections are **not** advertised as an
additional general-purpose posting visibility.

## NodeInfo: only AP software support

`metadata.fedibird` has schema version 1 and
`activitypub.supported`. There is no `rest`, translation,
account or viewer information. The NodeInfo adapter uses camelCase
(`schemaVersion`) rather than the REST serializer's `schema_version`.
No new NodeInfo discovery URL or schema version is introduced.

| Hint | Existing ActivityPub serialization |
| --- | --- |
| `emoji_react` | `ActivityPub::EmojiReactionSerializer` can emit `EmojiReact` |
| `note_references` | A local Note can publish a `references` collection |
| `legacy_quote_uri` | Note can publish `quoteUri` / `_misskey_quote` |
| `searchable_by` | Note / Actor expose `searchableBy` |
| `group_actor` | A local Group account serializes as `type: Group` |

These are **Fedibird-defined hints, not standard FEP IRIs**. In
particular `legacy_quote_uri` must not be interpreted as support for
newer quote FEP protocols. `group_actor` is not permission to post to
a remote group. The Fedibird local Group's Follow/mention/Announce
profile is distinct from remote Group profiles and FEP-5219
affiliations. See [group_protocol_profile.md](group_protocol_profile.md)
and [#662](https://github.com/fedibird/mastodon/issues/662).
Actor-level claims require a separate, validated implementation.

## Extension lifecycle and safety

- Do not mutate the legacy array or alter Mastodon version negotiation.
- Do not advertise UI-only card/Masonry/split layouts as REST features.
- Do not treat off-by-default write migrations (e.g. emoji fallback
  rollout), user-private RSS/Bluesky projections, or unknown remote
  group features as generally available.
- Keep the public catalog viewer-independent. Never access
  `current_user` or user-owned credentials from NodeInfo/instance.
- `/nodeinfo/2.0` is publicly cached for 30 minutes; instance API
  caching is also shared. Effective permissions must be queried from
  authenticated APIs, not stored here.
- Add new IDs only with route/serializer evidence, documented scope,
  flag behavior and tests.

Follow-up: [#727](https://github.com/fedibird/mastodon/issues/727)
for finer REST and dynamic availability,
[#728](https://github.com/fedibird/mastodon/issues/728) for actor
discovery and federation protocol review,
[#729](https://github.com/fedibird/mastodon/issues/729) for contract and
staging checks.
