# User-owned external credential vault

This is the M1 storage boundary for credentials a user supplies for an external service. It does not call DeepL, LibreTranslate, GitHub, or any other provider. It does not expose a settings page or a credential API.

## This is not end-to-end encryption

A Fedibird process that can read both the database and `USER_EXTERNAL_CREDENTIAL_KEYS` can decrypt every row. A server administrator with that same access can decrypt them too. If every key in the ring is lost, the ciphertext cannot be recovered and users must enter the credentials again.

The vault is encryption at rest plus a strict in-process use check. It does not make credentials unreadable to the server operator.

## What it does protect against

- A copy of the database, or of a database backup, without the vault keyring.
- Using one user's credential while acting for a different user.
- Using a credential for a different provider, purpose, or credential type than the one it was stored for.
- Copying `encrypted_payload` onto another row and decrypting it there.
- Plaintext in Rails parameter logs, model columns, `inspect`, or `as_json`.
- Plaintext in ActiveJob arguments, Redis, Rails.cache, serializers, InitialState, or Redux. M1 has no job and no API that returns the credential.
- Use of a revoked or expired credential.
- Being unable to rotate the encryption key without asking users to re-enter credentials.

M1 does not stop a malicious future provider adapter from leaking a credential after the vault has yielded it. Adapters are a separate review. M1 also does not decide whether a provider's terms allow this kind of delegation.

## Data flow

1. `UserCredentialVault.store!` or `replace!` receives plaintext in a method argument.
2. The vault builds a versioned JSON document, `{ "version": 1, "credentials": { ... } }`, and encrypts it immediately.
3. Only ciphertext is assigned to `user_external_credentials.encrypted_payload`, together with the non-secret columns (`user_id`, `provider`, `purpose`, `credential_type`, `binding_id`, `encryption_key_id`, `display_name`, `expires_at`, `revoked_at`).
4. `UserCredentialVault.with_credential` requires `owner`, `credential`, `provider`, `purpose`, and `credential_type` on every call.
5. The vault checks owner, classification, revocation, and expiry before decryption. Any mismatch raises and does not yield.
6. Decryption uses the key id stored on the row and an authenticated purpose built from that row. Failure raises and does not yield.
7. `last_used_at` is updated only after that decryption succeeds, and only if the row is still unrevoked and unexpired, immediately before the block runs.
8. The block receives a frozen hash. Callers must use it inside the block and must not return the credential itself. A future adapter returns the provider result (for example translated text), not the key.

Plaintext can exist in:

- the caller's argument to `store!` / `replace!`;
- short-lived locals inside `store!`, `replace!`, `with_credential`, and `UserCredentialVault::Rotation`;
- the object yielded to the `with_credential` block, until the caller drops it.

Ruby does not guarantee that those strings are erased from the heap. The vault drops its own references when the method leaves. That is lifetime minimization, not secure memory wiping.

Plaintext is not written to a model attribute, logger, exception message, notification, cache, Redis, or job argument.

Ciphertext is stored only in `user_external_credentials.encrypted_payload`. `inspect` filters that column. `as_json` / `to_json` omit it. M1 has no controller that renders the model.

## Environment

| Variable | Role |
| --- | --- |
| `USER_EXTERNAL_CREDENTIAL_KEYS` | `id:<base64>,id:<base64>` keyring. Each value is standard Base64 of 32 random bytes. |
| `USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY` | Key id used for new encryption and for rotation. |

Generate a key with:

```sh
ruby -rsecurerandom -rbase64 -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'
```

Duplicate key ids, malformed Base64, a trailing comma or empty entry, a decoded length other than 32 bytes, and a primary id that is not in the ring raise `UserCredentialVault::ConfigurationError` when the vault is used. Unset variables do not prevent boot. There is no fallback to `SECRET_KEY_BASE`, `OTP_SECRET`, or VAPID.

Never replace the bytes stored under an existing key id. Add a new id and leave the previous id mapped to its original bytes until rotation has finished and a later deploy removes the old id. Reusing an id with different material makes every row that names it unreadable.

## Encryption

- Primitive: `ActiveSupport::MessageEncryptor`
- Cipher: `aes-256-gcm` (AEAD)
- Serializer: `JSON.generate` / `JSON.parse` (no Marshal, no Oj, no `attr_encrypted`)
- Key: the raw 32-byte value selected from the keyring by `encryption_key_id`

`MessageEncryptor` places the purpose string inside the encrypted metadata. The GCM tag authenticates that metadata together with the payload. A purpose mismatch makes `decrypt_and_verify` return nil, which the vault turns into `AuthenticationFailure`. The exception message does not include plaintext or ciphertext.

## Authenticated context

The purpose string is exactly:

```text
user_external_credential:v1
<0x1E> payload_schema <0x1F> <byte length> <0x1F> <version>
<0x1E> binding_id      <0x1F> <byte length> <0x1F> <binding_id>
<0x1E> user_id         <0x1F> <byte length> <0x1F> <user id>
<0x1E> provider        <0x1F> <byte length> <0x1F> <provider>
<0x1E> purpose         <0x1F> <byte length> <0x1F> <purpose>
<0x1E> credential_type <0x1F> <byte length> <0x1F> <credential_type>
```

`binding_id` is a random UUID generated before encryption. Replacement generates a new `binding_id`, so the previous ciphertext does not authenticate under the replacement row. Copying ciphertext onto a row with a different owner, binding id, provider, purpose, or credential type fails authentication.

`provider`, `purpose`, and `credential_type` cannot be edited in place. Changing them requires an explicit decrypt and re-encrypt, which M1 does not offer as a casual update.

Payload schema version is fixed at `1` and is part of the purpose. A future version needs a non-secret version column (or an equivalent stored outside the ciphertext) so the purpose can be rebuilt without guessing.

## Ownership, revocation, expiry

- `user_id` is `NOT NULL`.
- `User has_many :external_credentials, dependent: :destroy`.
- The foreign key uses `ON DELETE CASCADE`.
- `with_credential` reloads the row by id and compares `owner.id` to that row's `user_id`. The ActiveRecord instance passed in is not the ciphertext that gets decrypted.
- After a successful decrypt, `last_used_at` is set only if `binding_id`, `provider`, `purpose`, and `credential_type` still match that row. A `replace!` that commits in between does not yield the previous secret. `encryption_key_id` is not part of this check, because key rotation changes it without changing the logical credential.
- Any non-nil `revoked_at` refuses decryption, including a timestamp in the future.
- `expires_at <= Time.current` refuses decryption. `nil` means no expiry.
- `revoke!` and `delete!` do not decrypt. Remote provider revocation is not part of M1.
- `replace!` keeps `revoked_at`, `expires_at`, and `display_name` unless the caller passes a new value. `nil` clears the column. Replacement does not silently reactivate a credential.

## Key rotation

```sh
DRY_RUN=1 bundle exec rake user_external_credentials:rotate
bundle exec rake user_external_credentials:rotate
bundle exec rake user_external_credentials:key_counts
```

`DRY_RUN` accepts `1`, `true`, or `yes`. The task prints counts, record ids, and error class names. It does not print plaintext or ciphertext. A failure raises after the run; unreadable rows are not deleted. Each rewritten row updates `encrypted_payload` and `encryption_key_id` in one conditional `UPDATE`.

Rotation decrypts every row, including a row whose `encryption_key_id` is already the primary id, and only then counts it as `already_primary`. A tampered primary-key row fails dry-run and write mode. `key_counts` only groups key ids. It does not decrypt, so a count of zero old-key rows does not prove the remaining ciphertext authenticates.

See `.env.production.sample` for the deploy order (add a new key id, switch primary, deploy, rotate, confirm, then remove the old key later). Do not replace the material of an existing key id.

## Future consumers

Provider adapters are reviewed separately and call a fixed endpoint. Do not grow a generic "credential + arbitrary URL" client.

Personal DeepL translation is `TranslationService::PersonalDeepL`. It calls `with_credential` on every translate and languages request. Its cache keys are under `v4:personal_translations/deepl/user/<user_id>/credential/<credential_id>/binding/<binding_id>/`. It does not read or write the shared instance keys:

- `v3:translations/<source>/<target>/<content hash>` in `TranslateStatusService`
- `translation_service/languages`

See `docs/personal_deepl_translation.md`. The vault itself does not choose a provider or write those caches.

If a job is added later, its arguments may contain only `owner_user_id`, `credential_id`, `provider`, `purpose`, and `credential_type`. The worker loads the row and calls `with_credential`.
