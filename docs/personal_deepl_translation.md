# Personal DeepL translation

This is the viewer-scoped DeepL provider. It is encryption-at-rest plus an application check, not end-to-end encryption. The server can decrypt a credential when it translates for that owner. Credential entry UI is a separate change.

## Provider precedence

`TranslationService.for_user(user)` resolves one viewer. `nil` stays on the instance provider. There is no thread-local current user.

1. One usable personal DeepL credential.
2. Instance DeepL (`DEEPL_API_KEY`, plan from `DEEPL_PLAN`).
3. Instance LibreTranslate (`LIBRE_TRANSLATE_ENDPOINT`).
4. Not configured.

`TranslationService.configured` and `TranslationService.configured?` remain the instance provider. `/api/v2/instance` `configuration.translation.enabled` and `GET /api/v1/instance/translation_languages` keep using them.

## Credential lookup

A row is usable for selection when all of these hold:

- `user_id` is the viewer
- `provider` is `deepl`
- `purpose` is `translation`
- `credential_type` is `api_key`
- `revoked_at` is null
- `expires_at` is null or greater than the current time

`UserCredentialVault.with_credential` repeats owner, provider, purpose, type, revocation, and expiry checks before any DeepL call. The encrypted payload is `{ "api_key": "..." }`.

Two or more usable rows for the same viewer fail closed. The resolver does not pick one by id and does not use the instance provider.

A row that is already revoked or expired at selection is absent. Instance fallback is then allowed. After `for_user` has returned personal DeepL, an invalid key, quota error, rate limit, DeepL outage, vault or keyring failure, replace/revoke race, or unexpected response stays on that personal provider.

## Endpoint

Inside the vault block, a personal key ending in `:fx` uses `https://api-free.deepl.com`. Any other personal key uses `https://api.deepl.com`. Instance `DEEPL_PLAN` is unchanged. There is no per-user endpoint, plan setting, or DeepL column.

The key is sent only as `Authorization: DeepL-Auth-Key ...`. It is not placed in the URL, query, or body.

## Plaintext lifetime

`TranslationService::PersonalDeepL` stores the owner, the credential record, and the non-secret cache scope (`user_id`, `credential_id`, `binding_id`, provider). It does not store the API key.

`translate` and `languages` each call `with_credential`. The block reads `payload['credentials']['api_key']`, builds `TranslationService::DeepL`, performs the synchronous request, and drops those locals before returning. The return value is the translation or the language map. Callers do not receive the key, the payload, or the DeepL client. Ruby does not guarantee those strings are wiped from memory.

## Cache keys

Personal result cache:

```text
v4:personal_translations/deepl/user/<user_id>/credential/<credential_id>/binding/<binding_id>/<source>/<target>/<content hash>
```

Personal language cache:

```text
v4:personal_translations/deepl/user/<user_id>/credential/<credential_id>/binding/<binding_id>/languages
```

The scope does not include the API key or a fingerprint of it. Two users do not share it. It is not the instance `v3:translations/...` key or `translation_service/languages`. `replace!` changes `binding_id` and therefore the scope. Encryption-key rotation keeps `binding_id`, so the scope stays. A revoked or deleted row is no longer selected. A cache hit does not decrypt and does not update `last_used_at`.

Instance providers keep the existing shared keys.

## Privacy

Personal DeepL reports `private_content_allowed? == false`. Public and unlisted statuses can be translated. Private, direct, limited, mutual, and personal statuses cannot. A viewer with personal DeepL does not fall back to a private-capable LibreTranslate endpoint for those statuses.

## In-flight requests

`with_credential` does not hold a row lock during the HTTP call. If revoke, delete, or replace wins before the vault yields, no DeepL request starts. If the request has already started, a later revoke or replace does not cancel that HTTP call. A cache hit on the scope selected at the start does not use the credential. A cache miss rechecks the current row. A result written to an old binding scope after a race is unreachable to the next resolution and is not written to a shared instance cache.

## HTTP surface

`GET /api/v1/fedibird/translation_languages` requires an authenticated user with `read` or `read:statuses`. It resolves `current_user` and returns the same language-map shape as the instance endpoint. A nil auto-detect source is `und` in the response. The response does not include credential ids, binding ids, key ids, ciphertext, or the API key. Personal failure does not fall back to the instance language map.

Logged-in WebUI fetches that path from `fetchServerTranslationLanguages`. Logged-out fetches stay on `/api/v1/instance/translation_languages`.

Status translation passes `user: current_user` into `TranslateStatusService`. The service resolves that user only.
