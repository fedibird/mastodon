# External services

This document is the design source of truth for the settings UI and future provider integrations. Secret storage stays in the user credential vault. See `docs/user_external_credential_vault.md` for the vault threat model and `docs/personal_deepl_translation.md` for the current DeepL translation behavior.

## External service connection != credential

An external service connection is the user-facing relationship with a remote service. A credential is only one piece of secret material that may be needed to operate that connection.

```text
External service connection != credential
```

A credential is not the connection. It is an implementation detail used to realize a connection, and some connections may need several credentials or none.

DeepL today is close to:

```text
connection
└── API key credential
```

A future Mastodon connection is a different shape:

```text
Mastodon connection
├── host
├── account identity
├── scopes
├── OAuth/token credential
└── capability metadata
```

Bluesky, Misskey, and PeerTube can differ again. A provider may also need no persistent secret.

The settings framework therefore lists and navigates **connections**. `UserExternalCredential` remains the low-level encrypted-secret store. It is not the connection model.

## Goals

- Give people one settings hub for the external services they have configured.
- Add further providers without a new top-level settings section or a generic secret form.
- Keep discovery, listing, navigation, and presentation separate from authentication.
- Show only safe metadata on the hub and on provider pages.
- Keep the current DeepL credential lifecycle and its security disclosures.

## Non-goals

- No database generalization in this design's first implementation.
- No generic metadata JSON column on `UserExternalCredential`.
- No generic credential mutation endpoint.
- No Mastodon, Misskey, PeerTube, or Bluesky authentication.
- No remote connection test for DeepL.
- No change to vault encryption, key rotation, or translation provider precedence.
- The hub status does not mean a remote service accepted a request.

## Terminology

| Term | Meaning |
| --- | --- |
| Provider | A kind of external service, such as DeepL or a future Mastodon integration. |
| Connection | One configured relationship between the viewer and a provider. A provider may have zero, one, or many. |
| Credential | Secret material stored for a connection. Not the connection itself. |
| Catalog | The Add service screen. It lists providers this version can actually configure. |
| Hub | The connection list at the canonical settings path. |
| Safe metadata | Names, labels, timestamps, and status that can be rendered without decrypting a secret. |

## Information architecture

```text
/settings/external_services                  hub of connections
/settings/external_services/new              Add service catalog
/settings/external_services/deepl            DeepL management
```

Settings navigation keeps the labels **External services** and **外部サービス**, and points at the hub.

The hub is not a credential form. Destructive actions are not on hub cards. Delete and replace happen on the provider page.

```text
External services                         Add service

┌─────────────────────────────────┐
│ [icon] DeepL          [Configured] │
│        Personal translation        │
│        Last used: ...              │
│                         Manage →   │
└─────────────────────────────────┘
```

A card may show:

- service icon
- service name
- connection or account label
- one short purpose or subtitle
- safe status
- last used or other activity time
- Manage link

A card must not show an API key, token, encrypted payload, binding id, encryption key id, or secret hash or fingerprint. Internal classification is not shown unless it is meaningful to the user. DeepL does not show `provider`, `purpose`, or `credential_type`.

## Provider registry

Providers are a static server-owned list. There is no plugin loader and no constantizing a request parameter.

```text
ExternalServices::Registry
ExternalServices::DeepL
```

A provider exposes the presentation contract:

```text
key
display_name
icon
description
available?
connections_for(user)
catalog_entry_for(user)
manage_path
```

`connections_for` returns an array of connection cards. It may return zero, one, or many. The hub must not assume one provider produces one card.

A connection card exposes only:

```text
provider_key
title
subtitle
status
status_label
last_used_at
manage_path
icon
```

The registry and the card objects must not decrypt credentials and must not return decrypted payloads. Provider code may read its own rows. It passes safe columns into the card. Ciphertext stays in the vault.

DeepL currently returns at most one logical connection, even when several credential rows exist. Those rows are a repair state on the DeepL page, not several hub cards.

## Add service catalog

The hub links to **Add service** / **サービスを追加**.

The catalog lists only providers implemented in this version. Disabled placeholders for Mastodon, Misskey, PeerTube, or Bluesky are not shown.

DeepL is the only catalog entry. If a DeepL connection already exists, including a duplicate or repair state, the entry links to Manage. It does not post a second generic create. If nothing is configured, Add opens the DeepL page, which owns the key form.

## Provider management pages

Each provider has its own page and its own mutation routes. The URL names the service, not the vault table.

DeepL:

```text
GET    /settings/external_services/deepl
POST   /settings/external_services/deepl/credential
DELETE /settings/external_services/deepl/credentials/:id
```

The page header is the shared icon, the service name, and a short description. Disclosures are a compact definition list, not a stack of unrelated hint paragraphs. Security and billing disclosures stay.

## No generic mutation

This shape is forbidden:

```text
POST /settings/external_services/:provider
provider=...
purpose=...
credential_type=...
secret=...
```

Future providers authenticate differently. The shared framework only discovers, lists, navigates, and presents. Creating, replacing, and deleting a secret stays on a provider-specific controller.

DeepL classification is fixed on the server:

```text
provider        = deepl
purpose         = translation
credential_type = api_key
```

The browser cannot choose those values.

## Multiple connections

One provider may show several connections. Examples:

```text
Mastodon
  @alice@example.social
  @alice@another.example

PeerTube
  alice@video.example
```

The hub renders one card per connection returned by the provider. DeepL remains one logical connection in the current UI. This design does not add a database uniqueness constraint.

## Provider-specific metadata

A future provider may need non-secret connection metadata, for example:

- host or domain
- remote account id
- handle or display name
- granted OAuth scopes
- token expiry
- capability or version information
- last successful sync or authentication

That metadata does not belong in a generic JSON column on `UserExternalCredential`. When a real provider needs it, add a connection metadata model with that provider. Until then, DeepL uses the existing credential row's safe timestamps and revocation columns only.

## Status vocabulary

Implemented card statuses:

```text
connected
warning
unavailable
```

Documented for later providers, not all produced today:

```text
connected
warning
expired
revoked
unavailable
error
```

`connected` means the local configuration is present and usable by the application's own rules. It does not mean a remote connection test succeeded. DeepL has no connection test. The user-facing label for DeepL's `connected` status is **Configured** / **設定済み**, not "verified" or "connected to DeepL".

DeepL mapping:

| Local state | Status |
| --- | --- |
| No row | No hub card. The catalog offers Add. |
| One row, not revoked or expired, vault available | `connected` |
| One revoked or expired row | `warning` |
| More than one row | `warning` |
| Vault unavailable while a row exists | `unavailable` |

Revoked, expired, duplicate, and vault-unavailable states must not claim that DeepL accepted the key. `last_used_at` is activity, not verification.

## DeepL page

The header describes personal translation. The note list covers:

- **Use.** Personal DeepL is preferred over the server translation provider. A failure does not silently switch to the server provider.
- **Content.** The visibility set in `docs/personal_deepl_translation.md`. After the merged personal-visibility policy, that is public, unlisted, and the viewer's own personal-only posts.
- **Storage.** The API key is encrypted at rest and cannot be shown again. This is not end-to-end encryption. An operator who can read both the database and the vault keys can decrypt it.
- **Contract.** Billing, quota, and terms belong to the user's own DeepL account.
- **Save and delete.** Saving does not contact DeepL. Deleting returns later translation to the normal instance-provider resolution when one is available.

One healthy row shows status, last used, created, and updated, then replace and delete. The API key field is empty on every GET.

Several rows show a warning and one safe record per row so the user can delete the extras. Replace and save stay fail closed. The page does not choose, merge, or delete a row on its own.

If the vault keyring is missing, the hub, the DeepL page, and safe metadata still render. Add and replace are disabled. Delete still works. The page does not print the configuration error or environment values.

## Brand icon policy

Provider icons are local files. Font Awesome brand glyphs are not the provider icon system. The app does not fetch icons from a CDN at runtime.

```text
app/javascript/images/external_services/
```

Only the icon for a provider that this version renders is vendored. Do not add unused Mastodon, Misskey, PeerTube, or Bluesky files ahead of those providers. Mastodon should first try the existing local Mastodon logo.

Every vendored file is recorded in `app/javascript/images/external_services/README.md` with the service, source, retrieval or version, and license or trademark note. If an official asset's redistribution terms are unclear, use a neutral glyph or initial authored for this repository. Do not copy the official mark.

Icons sit in a shared box of about 40–48 px so different shapes line up. Brand color stays inside that box. It does not paint the card. The service name next to the icon is the accessible name. The logo image is decorative and is not repeated to screen readers.

## Vault boundary

The vault encrypts and decrypts secrets, rotates keys, and enforces owner and classification checks. This settings framework does not.

| Concern | Owner |
| --- | --- |
| Ciphertext, binding id, key id | `docs/user_external_credential_vault.md` |
| DeepL provider selection and visibility | `docs/personal_deepl_translation.md` |
| Hub, catalog, routes, card status, copy | this document |

DeepL save and delete call the existing `DeepLCredentialSettings` service, which calls the vault. The registry does not.

## Sudo and session boundary

External services are HTML settings for a logged-in browser session. There is no credential REST API and no OAuth API that can mutate a credential.

The hub, the catalog, and the DeepL page share the existing sudo challenge. A page that needs the challenge sets `return_to` to that page's path with no query string. It does not use `request.url`, so a secret in the query cannot be copied into the challenge form.

Create, replace, and delete require a recent challenge. If the challenge is missing, the action redirects to the DeepL page and does not render a challenge form. The submitted secret is dropped with the request body. It is not placed in the challenge, the flash, or the redirect URL.

A user with no local password skips the challenge, as elsewhere in settings.

## Accessibility

- The service name is text beside the icon. The icon is hidden from assistive technology.
- Status is a text label. Color is not the only signal.
- Manage and Add name the service when more than one card can exist.
- Keyboard focus is visible on those links and on the card that contains them.
- Cards do not use a fixed height.
- The API key input remains a blank password field with `autocomplete="new-password"`.

## Responsive design

Settings-specific classes lay the cards out. They are not the WebUI timeline card styles.

Wide settings content uses two columns when the grid has room. Narrow and mobile content uses one column. The icon box, status, and actions align inside each card. Light and dark settings themes both use theme text and border colors. The card background is not a brand color.

## Route compatibility

Canonical routes are under `/settings/external_services`.

```text
GET /settings/external_credentials
```

redirects to the hub. The redirect target is a fixed path. The request query string is not copied.

Old DeepL mutation paths redirect to the DeepL page with `303 See Other`. They do not read the body and do not append submitted parameters to the URL. They do not save or delete. Current forms post and delete on the new DeepL routes.

No compatibility route accepts a secret-bearing GET query.

Existing DeepL rows are used as they are. No credential migration is required.

## Future provider onboarding checklist

1. Add a static provider object to `ExternalServices::Registry`. Do not constantize a request parameter.
2. Return zero or more connection cards from safe metadata. Do not decrypt in the registry.
3. Add a provider page and provider-specific mutation routes. Do not add a generic secret POST.
4. Show the provider in the catalog only when it can actually be configured.
5. Map local state onto the status vocabulary without claiming a remote test that the provider does not perform.
6. If a durable connection needs host, account, scope, expiry, or capability data, design that model with the provider. Do not add a generic metadata JSON column to the credential table.
7. Vendor an icon only for this provider, or reuse an existing local asset. Record provenance. Use a neutral glyph when redistribution is unclear.
8. Extend the sudo rule to the new mutation routes. Never carry a secret through the challenge or a redirect.
9. Document the provider next to this file and, when it stores a secret, next to the vault document.
