# AT Protocol OAuth identity connection

P2 connects a Fedibird user to their own AT Protocol account. It stores a verified DID, the PDS origin, the authorization-server issuer, and an encrypted OAuth session. It does not read a timeline, create a Status, deliver ActivityPub, or write a like, repost, or reply.

The authoritative profile is <https://atproto.com/specs/oauth>. Identity resolution follows <https://atproto.com/guides/identity>. This is not a generic OAuth or OpenID client, and it is not a client that always talks to `bsky.social`.

## What is not included

- No `com.atproto.repo.createRecord`, `putRecord`, or `deleteRecord`.
- No native like, repost, reply, or undo.
- No ActivityPub Create or Announce, and no synthetic Account.
- `PostingIdentity::ENABLED_KINDS` stays `local`. Bluesky is named there and is not enabled.
- No app passwords.
- The browser cannot choose `provider`, `purpose`, `credential_type`, or a token URL.

## Library choice

No Ruby gem implements this profile without dropping a required check. The reference client is the TypeScript package `@atproto/oauth-client`. Running that client would not share this process's `Request` SSRF checks or `UserCredentialVault`. Generic OAuth libraries do not do PAR, DPoP nonces, and `private_key_jwt` together with DID binding.

ES256 is signed with OpenSSL. Signatures are JOSE `R || S`, not ASN.1 DER. The client is the code under `app/services/external_bridge/atproto/`.

## Flags

Both defaults are deny:

```text
external_bridge_atproto: false
external_bridge_atproto_testers: ''
```

`ExternalBridge::Atproto::Feature` requires the boolean and an explicit user id. An empty allowlist admits nobody. Authorize, callback, and refresh all call it. Disconnect of an already stored row still revokes the local credential when the flag is off, and it does not send the refresh token while the user is not permitted. Turning the flag off does not delete identity rows.

`external_bridge_rss` is a different setting.

## Owner

`external_identities.user_id` and `external_oauth_attempts.user_id` are the owner. They are not `accounts.id`. Two users who share an account do not see or refresh each other's sessions. Deleting the user cascades both tables. The vault row cascades with the user as well.

The identity key is `(user_id, provider, subject)`. `subject` is the verified DID. A handle is display data and is not unique. One user may connect more than one DID. The same DID may be connected by more than one user. There is no global unique index on the DID.

## Discovery

The account field accepts a handle, `did:plc`, `did:web`, or an `https://` PDS or entryway origin. That value is never a URL that receives a token.

1. A handle is resolved by DNS TXT at `_atproto.<handle>`, then by `https://<handle>/.well-known/atproto-did` only when TXT has no DID. Conflicting TXT values are `discovery_rejected`. The DID document's `alsoKnownAs` must contain `at://<handle>`.
2. `did:plc` is fetched from `ATPROTO_PLC_DIRECTORY` (default `https://plc.directory`) with redirects disabled. `did:web` uses the method's encoding. Other DID methods are rejected.
3. The PDS is the `#atproto_pds` service whose type is `AtprotoPersonalDataServer`. Its endpoint must be an HTTPS origin with no userinfo, query, or private address.
4. `GET <pds>/.well-known/oauth-protected-resource` must be HTTP 200 JSON with exactly one `authorization_servers` origin. A 404 means the origin itself is the authorization server. That is the hostname-start case, and it does not bind a DID yet.
5. `GET <issuer>/.well-known/oauth-authorization-server` must be HTTP 200 JSON and must not redirect. `issuer` must equal that origin. The token, PAR, authorization, and revocation endpoints must be on that same origin. The document must require PAR, support `authorization_code` and `refresh_token`, PKCE `S256`, `private_key_jwt` with `ES256`, and DPoP `ES256`. `scopes_supported` must include `atproto`.

Every hop uses `ExternalBridge::Atproto::Destination` before `Request`. DNS answers are checked with `PrivateAddressCheck`. Metadata and token requests do not follow redirects. A discovery redirect is followed at most twice, and only for the handle well-known document, after the next URL passes the same checks. Redirects never carry `Authorization`, `DPoP`, or a token body.

A private address, a non-JSON document, a metadata status other than 200, or a token endpoint on a different host fails before a token is sent.

## Confidential client

`client_id` is the metadata document:

```text
GET /oauth/bluesky/client-metadata
GET /oauth/bluesky/jwks
```

`ClientDocument` publishes it only when `Rails.configuration.x.use_https` is true, `WEB_DOMAIN` has no port, the host is not local or private, and `ATPROTO_OAUTH_SIGNING_KEY` is a P-256 private key. Otherwise both endpoints return 404 and the provider is not offered.

The document sets `application_type=web`, `token_endpoint_auth_method=private_key_jwt`, `ES256`, `dpop_bound_access_tokens=true`, the code and refresh grants, and the scopes below. The private key is not in the document.

The AT Protocol localhost exception forces `token_endpoint_auth_method=none`. This client does not use it. A development PDS still needs a public HTTPS name.

### Key rotation

`ATPROTO_OAUTH_SIGNING_KEY` is the current PEM. Newlines may be written as `\n`. `ATPROTO_OAUTH_SIGNING_KID` is optional; the default kid is the RFC 7638 thumbprint.

The PAR request is signed with `SigningKey.current`. That key's `kid` is stored on the attempt as `client_key_id`. The callback, a revocation after a failed callback, and the vault session all use `SigningKey.for_kid` for that same id. Publishing the old public key in JWKS does not permit the token exchange to switch to a newer key. If that private key is no longer configured, the callback raises `signing_key_unavailable`, does not consume the attempt, and does not send the authorization code. Refresh of a session whose kid was removed is `reauthentication_required`, and the refresh token is not sent.

`ATPROTO_OAUTH_PREVIOUS_SIGNING_KEYS` keeps the private key available for attempts and sessions that already used it:

```text
ATPROTO_OAUTH_PREVIOUS_SIGNING_KEYS=oldkid:<base64 of the old PEM>
```

Set the new PEM as `ATPROTO_OAUTH_SIGNING_KEY` only after the previous private key is in that list. This key is never written to `user_external_credentials`.

### Authorization

1. The settings session creates a browser token stored only in the Rails session.
2. PKCE S256 and a fresh P-256 DPoP key are created. The verifier and the DPoP private key are encrypted with the vault cipher into `external_oauth_attempts`, bound to `user_id` and a random `binding_id`. The row also stores the non-secret `client_key_id` of the signing key used for this attempt. The row expires in ten minutes.
3. PAR is posted to the metadata PAR endpoint and signed with that same key. The client assertion's `aud` is the bound issuer. Each request has its own DPoP proof. A `use_dpop_nonce` response is retried once with the returned nonce. Redirects are rejected.
4. The browser is sent to the metadata authorization endpoint with `client_id` and `request_uri` only.

The attempt stores the issuer, PDS origin when one was verified, token endpoint, and requested scopes. It does not store the authorization code.

A user may have at most five unconsumed, unexpired attempts, and at most ten attempts created in the ten-minute window. Another user's attempts do not count. A further start is `attempt_rate_limited` and does not call PAR when the cap is already reached. The locked recheck inside the insert transaction is what makes the cap hold for two overlapping requests.

`Scheduler::ExternalBridgeAtprotoAttemptCleanupScheduler` runs every ten minutes. Each run deletes at most 1,000 rows: expired attempts that were never consumed, and consumed tombstones, in batches of 200. It selects ids and uses `delete_all`. It does not decrypt or log `encrypted_secrets`, and it does not delete an unexpired attempt that has not been consumed. A larger backlog continues on the next run.

### Callback

`GET /settings/external_services/bluesky/callback` checks, in order:

- the signed-in user
- a provider `error` parameter, without copying it into the flash
- state digest, browser-token digest, expiry, and single use
- the feature flag and allowlist
- callback `iss` equal to the attempt issuer
- the code, then the token POST to the stored token endpoint, signed with `client_key_id`

The signing key is loaded before the attempt is consumed. A missing key rolls that back, so the attempt can be retried only if the same key is restored. Otherwise the user starts again. Once the key is present, the attempt is consumed before the token POST. A second callback with the same state fails. The vault row stores that same `client_key_id`. The token response must be `token_type=DPoP`, `sub` must be `did:plc` or `did:web`, and `scope` must contain `atproto` and no scope that was not requested. `transition:chat`, `transition:email`, `blob:`, `account:`, and `rpc:` are rejected. The DID is resolved again. Its PDS protected-resource issuer must still be the attempt issuer. Only then are the vault row and `external_identities` row committed in one transaction.

A failed check after tokens were issued posts the refresh token to the stored revocation endpoint and does not leave an active identity. A disconnect or a newer successful callback for the same DID that landed first makes this callback `stale_callback`.

### Scopes

P2 requests only `atproto`. One advertised `repo:` scope is not treated as permission to ask for like, repost, and post together, and `transition:generic` is not requested. The client metadata document advertises `atproto` only. Chat, email, account, and blob scopes are rejected if a server adds them to the grant.

`Scopes::REPO` lists `repo:app.bsky.feed.like`, `repo:app.bsky.feed.repost`, and `repo:app.bsky.feed.post` for a later upgrade. That upgrade is not part of P2. It has to be a separate user confirmation, and it may request only the intersection of that list with the server's `scopes_supported`. The settings page says the current connection is identity-only.

A grant that adds a scope is not stored. `Scopes.accept!` still records a proper subset as `warning` / `partial_scopes` for a future multi-scope request. P2's single-scope request has no smaller successful subset.

### Refresh and disconnect

Refresh takes an identity id, not a URL. It resolves the DID and reads authorization-server metadata before it decides to send a token. Nothing is sent to an origin those checks did not verify.

A temporary failure of that read — HTTP 503, a timeout, a connection error, or other `discovery_rejected` — sets `last_error_code` and `last_checked_at` and leaves `status` unchanged. The credential is not revoked. The settings page shows the error, and the next check may run immediately. There is no blocking backoff. A confirmed issuer change (`issuer_mismatch`), a token endpoint that is no longer the stored endpoint, or authorization-server metadata that no longer supports `atproto` (`unsupported_scopes`) sets `reauthentication_required`. The refresh token is not sent, including on a later check after the service recovers. The token request, when the checks pass, goes only to the endpoint stored from that metadata, with DPoP and the client key named by the session.

The row update that sets `refresh_started_at` is committed before that HTTP request. The database transaction is not held open across the network call. A second caller sees the marker and does not send the refresh token. If the process dies after the authorization server consumes the token and before the new ciphertext is committed, the marker remains. The next call does not send the old token again. The user signs in again.

A successful token response is stored only when `sub` is the same verified DID already on the identity, `token_type` is `DPoP`, and the scope is a subset of the scopes this identity was granted. A missing subject, an invalid DID, a different DID, or a returned issuer that is not the bound issuer does not replace the vault row. The local credential is revoked and the in-flight marker stays, so the wrong token is not kept as this user's session. There is no repository write on that path.

Refresh tokens are single use. A timeout is `refresh_unacknowledged`. A 401, a revoked or expired vault row, or a missing signing key is `reauthentication_required` or `revoked`. The old ciphertext is replaced only after the subject check and the rest of the response checks succeed.

If disconnect commits while the refresh POST is in flight, the local row stays disconnected and the vault row stays revoked. The token response can still contain a new refresh token. Revoking the token disconnect already submitted does not revoke that successor on every authorization server. Refresh therefore submits the new refresh token to the same bound revocation endpoint, with the session DPoP key and the pinned client key, including when the local result is `revoked`. The new token is not written to the vault or to the identity row. `successor_revoked` means that POST was accepted. `successor_revoke_failed` means it was not. `remote_revoked` refers only to the token disconnect itself submitted. Disconnect will not overwrite a successor result that was recorded first.

If the process dies after that token response is received and before the successor POST, the new token existed only in memory. It was not stored, so a later process cannot revoke it. That lost acknowledgment is the remaining limit of this path. The local session is still disconnected.

Disconnect commits the local vault revoke and `disconnected_at` before it tries the remote revocation endpoint. Preparing that request cannot stop the local commit. A decrypted payload that has no refresh token, no DPoP private key, or no configured signing kid is `remote_failed`, and no request is sent. Remote revocation uses the refresh token already read from the vault and the stored revocation endpoint. It does not choose a URL from the request. `revocation_state` is then `remote_revoked` or `remote_failed` when no successor token was received. If the process dies between the local commit and the remote call, the row stays disconnected and the credential stays revoked. `not_supported` means the server published no revocation endpoint. `not_attempted` means this server did not send the token, including when the flag no longer permits the user. A failed remote revoke is not reported as success. A callback or refresh that finishes after `disconnected_at` does not reactivate the row.

## Vault

Classification is fixed in `ExternalBridge::Atproto::Codes`:

```text
provider        = bluesky
purpose         = identity
credential_type = oauth_session
```

`UserCredentialVault.store!` and `replace!` encrypt the refresh token, access token, DPoP private key, nonce, token endpoint, issuer, client kid, granted scope, and session generation. `external_identities` stores the DID, handle, issuer, PDS origin, granted scopes, and status. It does not store tokens.

OAuth attempt secrets use the same keyring and a different encryption purpose, `external_oauth_attempt:v1`, so a copied ciphertext does not decrypt as a vault credential. `encrypted_secrets` is in `filter_attributes`. Log filters also cover `code`, `state`, `code_verifier`, `client_assertion`, `dpop`, `access_token`, and `refresh_token`.

## Routes

```text
GET    /oauth/bluesky/client-metadata
GET    /oauth/bluesky/jwks
GET    /settings/external_services/bluesky
POST   /settings/external_services/bluesky/authorize
GET    /settings/external_services/bluesky/callback
DELETE /settings/external_services/bluesky/identities/:id
POST   /settings/external_services/bluesky/identities/:id/check
```

There is no `POST /settings/external_services/:provider`. Authorize, disconnect, and check require a recent sudo challenge. The callback is allowed through without a second password because the browser is returning from the authorization server; the OAuth state and the session browser token are the check. The redirect back to settings does not keep `code` or `state` on the query string.

Errors shown to the user are the codes in `ExternalBridge::Atproto::Codes`, translated in English and Japanese. Raw provider bodies are not copied into the flash.

## Migration

`db/migrate/20261020130000_create_external_atproto_identities.rb` creates `external_identities` and `external_oauth_attempts`. It does not touch `statuses`. `change` drops both tables on rollback. Rolling back does not decrypt or export tokens. Vault rows are removed by the user foreign key when the user is deleted, and disconnect revokes them in place. A rollback that drops only the identity tables leaves revoked or live vault rows; operators should disconnect identities before rolling back if remote revocation matters.

## Rollout gate

Do not set `external_bridge_atproto` until all of the following are true:

1. `WEB_DOMAIN` is the public HTTPS name, with no port.
2. `https://<WEB_DOMAIN>/oauth/bluesky/client-metadata` and `/oauth/bluesky/jwks` answer 200 from the public internet.
3. `ATPROTO_OAUTH_SIGNING_KEY` is present only in the process environment.
4. A tester id is added to `external_bridge_atproto_testers`.
5. That tester completes a real authorization against a PDS, including a separate entryway if one is used, then refresh and disconnect. A stubbed test is not this step.
6. The tester confirms the page shows the DID, handle, issuer, and PDS, and does not show a token.

The automated specs in `spec/services/external_bridge/atproto/` and `spec/controllers/settings/external_services/bluesky_controller_spec.rb` stub DNS and HTTP. They do not perform that live authorization. The flag remains false in `config/settings.yml`.
