# frozen_string_literal: true

# User-owned external credential vault.
#
# This is encryption at rest and an application-level use boundary. It is not
# end-to-end encryption. A server administrator, or any process that can read
# both the database and USER_EXTERNAL_CREDENTIAL_KEYS, can decrypt credentials.
# Do not describe this vault as unreadable by the server operator.
#
# Plaintext exists only as local objects inside store!, replace!,
# with_credential, and key rotation, and inside the with_credential block the
# caller supplies. Ruby cannot guarantee that those strings are wiped from
# memory. Dropping references below is lifetime minimization, not secure
# erasure.
#
# The vault refuses to decrypt unless the caller restates the owner, provider,
# purpose, and credential type, and those values match the row. Revoked and
# expired rows are not yielded. There is no model method that returns
# plaintext.
#
# Future background jobs must enqueue only owner_user_id, credential_id,
# provider, purpose, and credential_type. The worker reloads the row, repeats
# these checks, and decrypts inside the worker. Never enqueue plaintext.
#
# Future provider adapters must not accept a credential plus an arbitrary URL.
# That would be an SSRF and credential-exfiltration primitive. Adapters are
# reviewed separately and call a fixed provider endpoint.
#
# Personal translation caches must not reuse the shared instance keys
# `v3:translations/<source>/<target>/<content hash>` or
# `translation_service/languages`. TranslationService::PersonalDeepL uses
# `v4:personal_translations/deepl/user/<user_id>/credential/<credential_id>/binding/<binding_id>/...`.
# This vault does not read or write those caches.
module UserCredentialVault
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class AccessError < Error; end
  class OwnerMismatch < AccessError; end
  class ProviderMismatch < AccessError; end
  class PurposeMismatch < AccessError; end
  class CredentialTypeMismatch < AccessError; end
  class Revoked < AccessError; end
  class Expired < AccessError; end

  class IntegrityError < Error; end
  class UnknownKey < IntegrityError; end
  class AuthenticationFailure < IntegrityError; end
  class MalformedPayload < IntegrityError; end

  class RotationError < Error
    attr_reader :report

    def initialize(report)
      @report = report
      super("user external credential rotation failed for #{report.failures.size} record(s)")
    end
  end

  # Sentinel for replace! fields that must stay as they are. Passing nil is
  # an explicit clear. Omitting the argument is not.
  UNCHANGED = Object.new.freeze
  private_constant :UNCHANGED

  class << self
    # Encrypts credentials immediately and persists ciphertext only.
    # Returns the record. Does not return plaintext.
    #
    # rubocop:disable Metrics/ParameterLists -- caller must name every access-boundary field
    def store!(owner:, provider:, purpose:, credential_type:, credentials:, display_name: nil, expires_at: nil)
      raise ArgumentError, 'owner is required' unless owner.is_a?(User) && owner.persisted?

      provider = Identifiers.check!(:provider, provider)
      purpose = Identifiers.check!(:purpose, purpose)
      credential_type = Identifiers.check!(:credential_type, credential_type)
      display_name = normalize_display_name(display_name)
      expires_at = normalize_time(expires_at, 'expires_at')

      keyring = Keyring.load!
      binding_id = SecureRandom.uuid
      # rubocop:disable Lint/UselessAssignment -- release plaintext/ciphertext references; this is not memory zeroization
      payload = nil
      ciphertext = nil

      begin
        payload = Payload.wrap(credentials)
        ciphertext = Cipher.encrypt(payload, key: keyring.primary_key, purpose: context_for(owner.id, binding_id, provider, purpose, credential_type))
        UserExternalCredential.create!(
          user_id: owner.id,
          provider: provider,
          purpose: purpose,
          credential_type: credential_type,
          binding_id: binding_id,
          encrypted_payload: ciphertext,
          encryption_key_id: keyring.primary_id,
          display_name: display_name,
          expires_at: expires_at
        )
      ensure
        payload = nil
        ciphertext = nil
      end
      # rubocop:enable Lint/UselessAssignment
    end

    # Re-encrypts under a new binding_id and the primary key.
    #
    # revoked_at, expires_at, and display_name are left unchanged unless the
    # caller passes a value. nil clears that column. This method does not
    # silently reactivate a revoked or expired credential, and it does not
    # change provider, purpose, or credential_type.
    def replace!(owner:, credential:, provider:, purpose:, credential_type:, credentials:, display_name: UNCHANGED, expires_at: UNCHANGED, revoked_at: UNCHANGED)
      Guard.credential!(credential)
      Guard.owner!(owner, credential)
      provider = Identifiers.check!(:provider, provider)
      purpose = Identifiers.check!(:purpose, purpose)
      credential_type = Identifiers.check!(:credential_type, credential_type)
      Guard.classification!(credential, provider: provider, purpose: purpose, credential_type: credential_type)

      keyring = Keyring.load!
      binding_id = SecureRandom.uuid
      # rubocop:disable Lint/UselessAssignment -- release plaintext/ciphertext references; this is not memory zeroization
      payload = nil
      ciphertext = nil

      begin
        payload = Payload.wrap(credentials)
        ciphertext = Cipher.encrypt(payload, key: keyring.primary_key, purpose: context_for(credential.user_id, binding_id, provider, purpose, credential_type))
        UserExternalCredential.transaction do
          locked = UserExternalCredential.lock.find(credential.id)
          Guard.owner!(owner, locked)
          Guard.classification!(locked, provider: provider, purpose: purpose, credential_type: credential_type)
          locked.binding_id = binding_id
          locked.encrypted_payload = ciphertext
          locked.encryption_key_id = keyring.primary_id
          assign_unless_unchanged(locked, :display_name, display_name) { |value| normalize_display_name(value) }
          assign_unless_unchanged(locked, :expires_at, expires_at) { |value| normalize_time(value, 'expires_at') }
          assign_unless_unchanged(locked, :revoked_at, revoked_at) { |value| normalize_time(value, 'revoked_at') }
          locked.save!
        end
        credential.reload
      ensure
        payload = nil
        ciphertext = nil
      end
      # rubocop:enable Lint/UselessAssignment
    end
    # rubocop:enable Metrics/ParameterLists

    # Yields plaintext only after owner, provider, purpose, type, revocation,
    # expiry, and authenticated decryption all succeed. The block value is
    # returned so a caller can return a non-secret result. Do not return the
    # payload itself from the block.
    #
    # The caller-supplied record is only an id. Decryption reloads the current
    # row, so a stale instance cannot yield the secret from before replace!.
    # mark_used! then requires that same binding_id and classification. If
    # replacement commits after the reload, the update matches nothing and the
    # block is not called. encryption_key_id is not part of that check: key
    # rotation keeps the logical credential and the same binding_id.
    def with_credential(owner:, credential:, provider:, purpose:, credential_type:)
      raise ArgumentError, 'a block is required' unless block_given?

      Guard.credential!(credential)
      provider = Identifiers.check!(:provider, provider)
      purpose = Identifiers.check!(:purpose, purpose)
      credential_type = Identifiers.check!(:credential_type, credential_type)

      keyring = Keyring.load!
      # rubocop:disable Lint/UselessAssignment -- release plaintext references; this is not memory zeroization
      payload = nil
      frozen = nil

      begin
        current = current_credential!(credential.id, owner: owner, provider: provider, purpose: purpose, credential_type: credential_type)
        payload = read_payload!(current, keyring)
        frozen = freeze_payload(payload)
        payload = nil
        mark_used!(current)
        yield frozen
      ensure
        payload = nil
        frozen = nil
      end
      # rubocop:enable Lint/UselessAssignment
    end

    # Local revocation only. Does not call a remote provider and does not decrypt.
    def revoke!(owner:, credential:)
      Guard.credential!(credential)
      Guard.owner!(owner, credential)
      credential.update!(revoked_at: Time.current) if credential.revoked_at.nil?
      credential
    end

    # Hard-deletes one row after an ownership check. Does not decrypt.
    def delete!(owner:, credential:)
      Guard.credential!(credential)
      Guard.owner!(owner, credential)
      credential.destroy!
      credential
    end

    def rotate_encryption_keys!(dry_run: false)
      report = Rotation.call(dry_run: dry_run)
      raise RotationError, report if report.failures.any?

      report
    end

    private

    def context_for(user_id, binding_id, provider, purpose, credential_type)
      Context.build(
        payload_schema: Payload::VERSION,
        binding_id: binding_id,
        user_id: user_id,
        provider: provider,
        purpose: purpose,
        credential_type: credential_type
      )
    end

    def current_credential!(credential_id, owner:, provider:, purpose:, credential_type:)
      current = UserExternalCredential.find(credential_id)
      Guard.owner!(owner, current)
      Guard.classification!(current, provider: provider, purpose: purpose, credential_type: credential_type)
      Guard.usable!(current)
      current
    rescue ActiveRecord::RecordNotFound
      raise AccessError, 'credential is not usable'
    end

    def read_payload!(credential, keyring)
      raw = Cipher.decrypt(
        credential.encrypted_payload,
        key: keyring.key_for!(credential.encryption_key_id),
        purpose: context_for(credential.user_id, credential.binding_id, credential.provider, credential.purpose, credential.credential_type)
      )
      Payload.unwrap(raw)
    end

    # binding_id is the replacement generation. provider, purpose, and
    # credential_type are the classification the caller just authenticated.
    # encryption_key_id is omitted because rotation changes it without
    # changing that logical credential.
    def mark_used!(credential)
      now = Time.current
      scope = UserExternalCredential.where(
        id: credential.id,
        user_id: credential.user_id,
        binding_id: credential.binding_id,
        provider: credential.provider,
        purpose: credential.purpose,
        credential_type: credential.credential_type,
        revoked_at: nil,
        expires_at: credential.expires_at
      )
      updated = scope.where('expires_at IS NULL OR expires_at > ?', now).update_all(last_used_at: now)
      raise AccessError, 'credential is not usable' unless updated == 1

      credential.last_used_at = now
    end

    def freeze_payload(payload)
      credentials = {}
      payload.fetch('credentials').each do |key, value|
        credentials[key.dup.freeze] = value.dup.freeze
      end
      { 'version' => payload.fetch('version'), 'credentials' => credentials.freeze }.freeze
    end

    def assign_unless_unchanged(record, attribute, value)
      return if value.equal?(UNCHANGED)

      record.public_send("#{attribute}=", yield(value))
    end

    def normalize_display_name(value)
      return nil if value.nil?
      raise ArgumentError, 'display_name is invalid' unless value.is_a?(String)

      stripped = value.strip
      return nil if stripped.empty?
      raise ArgumentError, 'display_name is invalid' if stripped.match?(UserExternalCredential::CONTROL_CHARACTERS) || stripped.length > 100

      stripped
    end

    def normalize_time(value, name)
      return nil if value.nil?
      raise ArgumentError, "#{name} is invalid" unless value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      value
    end
  end
end
