require 'rails_helper'

RSpec.describe UserCredentialVault, type: :service do
  let(:owner) { Fabricate(:user) }
  let(:other_user) { Fabricate(:user) }

  def documented_context(payload_schema:, binding_id:, user_id:, provider:, purpose:, credential_type:)
    fields = [
      ['payload_schema', payload_schema.to_s],
      ['binding_id', binding_id],
      ['user_id', user_id.to_s],
      ['provider', provider],
      ['purpose', purpose],
      ['credential_type', credential_type],
    ]
    encoded = fields.map { |name, value| "#{name}\x1f#{value.bytesize}\x1f#{value}" }.join("\x1e")
    "user_external_credential:v1\x1e#{encoded}"
  end

  describe 'authenticated context' do
    let(:binding_id) { '11111111-1111-4111-8111-111111111111' }

    it 'uses the documented length-prefixed purpose and does not embed the secret' do
      kwargs = {
        payload_schema: 1,
        binding_id: binding_id,
        user_id: 12,
        provider: 'deepl',
        purpose: 'translation',
        credential_type: 'api_key',
      }

      expect(UserCredentialVault::Context.build(**kwargs)).to eq(documented_context(**kwargs))
      expect(UserCredentialVault::Context.build(**kwargs)).not_to include(vault_secret)
    end

    it 'does not treat concatenated provider and purpose values as the same context' do
      shared = {
        payload_schema: 1,
        binding_id: binding_id,
        user_id: 12,
        credential_type: 'api_key',
      }
      left = shared.merge(provider: 'ab', purpose: 'c')
      right = shared.merge(provider: 'a', purpose: 'bc')

      expect(UserCredentialVault::Context.build(**left)).to eq(documented_context(**left))
      expect(UserCredentialVault::Context.build(**left)).not_to eq(UserCredentialVault::Context.build(**right))
    end

    it 'uses aes-256-gcm' do
      expect(UserCredentialVault::Cipher::CIPHER_NAME).to eq('aes-256-gcm')
      expect(OpenSSL::Cipher.new('aes-256-gcm').authenticated?).to be(true)
      expect(UserCredentialVault::Cipher::KEY_LENGTH).to eq(32)
    end
  end

  describe 'configuration' do
    it 'does not require the keyring while the process is booting or the class is loaded' do
      with_vault_keyring(primary: '', keys: '') do
        expect(UserCredentialVault::Keyring.configured?).to be(false)
        expect { UserExternalCredential.new }.not_to raise_error
        expect { described_class::Keyring.configured? }.not_to raise_error
      end
    end

    it 'fails closed when key material is missing and does not fall back to SECRET_KEY_BASE' do
      ClimateControl.modify(
        USER_EXTERNAL_CREDENTIAL_KEYS: '',
        USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY: '',
        SECRET_KEY_BASE: 'a' * 128,
        OTP_SECRET: 'b' * 128,
      ) do
        expect { store_vault_credential(owner: owner) }.to raise_error(described_class::ConfigurationError, /not configured/)
      end

      expect(UserExternalCredential.count).to eq(0)
    end

    it 'fails closed on a malformed keyring, a short key, a duplicate id, and a missing primary id' do
      encoded = vault_key_material.fetch('v1')
      other = vault_key_material.fetch('v2')
      short_key = Base64.strict_encode64('a' * 16)
      cases = [
        ['v1', 'v1:%%%not-base64%%%', /malformed/],
        ['v1', "v1:#{short_key}", /32 bytes/],
        ['v1', "v1:#{encoded},v1:#{other}", /duplicate/],
        ['v1', "v1:#{encoded}, v2:#{other}", /malformed/],
        ['v2', "v1:#{encoded}", /not in the keyring/],
      ]

      cases.each do |primary, serialized, message|
        with_vault_keyring(primary: primary, keys: serialized) do
          expect { store_vault_credential(owner: owner) }.to raise_error(described_class::ConfigurationError, message) { |error|
            expect(error.message).not_to include(encoded)
            expect(error.message).not_to include(other)
            expect(error.message).not_to include(short_key)
          }
        end
      end

      expect(UserExternalCredential.count).to eq(0)
    end

    it 'does not include key material in the keyring inspect string' do
      with_vault_keyring do
        keyring = described_class::Keyring.load!
        expect(keyring.inspect).to include('v1', 'v2')
        expect(keyring.inspect).not_to include(vault_key_material.fetch('v1'))
        expect(keyring.inspect).not_to include(vault_key_material.fetch('v2'))
      end
    end
  end

  describe 'store and use' do
    it 'persists ciphertext only and yields for the matching owner, provider, purpose, and type' do
      record = nil
      with_vault_keyring do
        record = store_vault_credential(owner: owner, display_name: 'Personal DeepL')
      end

      expect(record.encryption_key_id).to eq('v2')
      expect(record.binding_id).to match(UserExternalCredential::BINDING_ID_FORMAT)
      expect(record.display_name).to eq('Personal DeepL')
      expect(record).not_to respond_to(:secret)
      expect(record).not_to respond_to(:decrypted_payload)
      expect(record.class.column_names).not_to include('metadata', 'api_key', 'secret', 'credentials', 'payload')
      expect(persisted_row_text(record)).not_to include(vault_secret)
      expect(record.encrypted_payload).not_to include(vault_secret)
      expect(record.inspect).not_to include(vault_secret)
      expect(record.inspect).not_to include(record.encrypted_payload)
      expect(record.inspect).to include('[FILTERED]')
      expect(record.as_json).not_to have_key('encrypted_payload')
      expect(record.as_json(only: [:encrypted_payload])).not_to have_key('encrypted_payload')
      expect(record.to_json).not_to include(vault_secret)

      with_vault_keyring do
        probe = probe_vault(owner: owner, credential: record)
        expect(probe[:yielded]).to be(true)
        expect(probe[:error]).to be_nil
        expect(probe[:result]).to eq(vault_secret)
        expect(record.reload.last_used_at).to be_present
      end
    end

    it 'accepts a symbolized credential field and a still-valid expiry' do
      with_vault_keyring do
        record = described_class.store!(
          owner: owner,
          provider: 'deepl',
          purpose: 'translation',
          credential_type: 'api_key',
          credentials: { api_key: vault_secret },
          expires_at: 1.hour.from_now,
        )
        probe = probe_vault(owner: owner, credential: record)

        expect(probe[:yielded]).to be(true)
        expect(probe[:result]).to eq(vault_secret)
      end
    end

    it 'rejects identifiers that are not short machine-readable names' do
      with_vault_keyring do
        expect { store_vault_credential(owner: owner, provider: 'DeepL') }.to raise_error(ArgumentError, 'provider is not a valid identifier')
        expect { store_vault_credential(owner: owner, purpose: "translation\n") }.to raise_error(ArgumentError, 'purpose is not a valid identifier')
        expect { store_vault_credential(owner: owner, credential_type: 'a' * 65) }.to raise_error(ArgumentError, 'credential_type is not a valid identifier')
      end

      expect(UserExternalCredential.count).to eq(0)
    end

    it 'rejects a nested credential value without echoing it' do
      with_vault_keyring do
        expect do
          described_class.store!(
            owner: owner,
            provider: 'deepl',
            purpose: 'translation',
            credential_type: 'api_key',
            credentials: { 'api_key' => { 'nested' => vault_secret } },
          )
        end.to raise_error(ArgumentError, 'credential values must be strings') { |error|
          expect(error.message).not_to include(vault_secret)
        }
      end

      expect(UserExternalCredential.count).to eq(0)
    end

    it 'allows more than one credential for the same owner, provider, and purpose' do
      with_vault_keyring do
        first = store_vault_credential(owner: owner)
        second = store_vault_credential(owner: owner, secret: "#{vault_secret}-other")

        expect(first.binding_id).not_to eq(second.binding_id)
        expect(probe_vault(owner: owner, credential: second)[:result]).to eq("#{vault_secret}-other")
      end
    end
  end

  describe 'rejection before use' do
    let(:record) do
      with_vault_keyring { store_vault_credential(owner: owner) }
    end

    it 'rejects the wrong owner and does not yield or touch last_used_at' do
      with_vault_keyring do
        probe = probe_vault(owner: other_user, credential: record)

        expect(probe[:yielded]).to be(false)
        expect(probe[:error]).to be_a(described_class::OwnerMismatch)
        expect(probe[:error].message).to eq('credential owner mismatch')
        expect(record.reload.last_used_at).to be_nil
      end
    end

    it 'rejects the wrong provider, purpose, and credential type' do
      with_vault_keyring do
        provider = probe_vault(owner: owner, credential: record, provider: 'libre')
        purpose = probe_vault(owner: owner, credential: record, purpose: 'search')
        type = probe_vault(owner: owner, credential: record, credential_type: 'oauth')

        expect(provider[:yielded]).to be(false)
        expect(provider[:error]).to be_a(described_class::ProviderMismatch)
        expect(purpose[:yielded]).to be(false)
        expect(purpose[:error]).to be_a(described_class::PurposeMismatch)
        expect(type[:yielded]).to be(false)
        expect(type[:error]).to be_a(described_class::CredentialTypeMismatch)
        expect(record.reload.last_used_at).to be_nil
      end
    end

    it 'rejects a revoked credential, including one revoked in the future' do
      with_vault_keyring do
        described_class.revoke!(owner: owner, credential: record)
        probe = probe_vault(owner: owner, credential: record.reload)
        expect(probe[:yielded]).to be(false)
        expect(probe[:error]).to be_a(described_class::Revoked)

        record.update!(revoked_at: 1.day.from_now)
        future = probe_vault(owner: owner, credential: record)
        expect(future[:yielded]).to be(false)
        expect(future[:error]).to be_a(described_class::Revoked)
        expect(record.reload.last_used_at).to be_nil
      end
    end

    it 'rejects an expired credential and accepts one that is not yet expired' do
      with_vault_keyring do
        expired = store_vault_credential(owner: owner, secret: "#{vault_secret}-expired", expires_at: 1.minute.ago)
        fresh = store_vault_credential(owner: owner, secret: "#{vault_secret}-fresh", expires_at: 1.hour.from_now)

        denied = probe_vault(owner: owner, credential: expired)
        allowed = probe_vault(owner: owner, credential: fresh)

        expect(denied[:yielded]).to be(false)
        expect(denied[:error]).to be_a(described_class::Expired)
        expect(expired.reload.last_used_at).to be_nil
        expect(allowed[:yielded]).to be(true)
        expect(allowed[:result]).to eq("#{vault_secret}-fresh")
      end
    end

    it 'treats expires_at equal to the current time as expired' do
      now = Time.current.change(usec: 0)
      travel_to(now) do
        with_vault_keyring do
          record = store_vault_credential(owner: owner, expires_at: now)
          probe = probe_vault(owner: owner, credential: record)
          expect(probe[:yielded]).to be(false)
          expect(probe[:error]).to be_a(described_class::Expired)
        end
      end
    end
  end

  describe 'ciphertext binding' do
    it 'rejects tampered ciphertext, a copied binding, a copied owner, and a copied classification' do
      with_vault_keyring do
        source = store_vault_credential(owner: owner)
        original_ciphertext = source.encrypted_payload
        original_key_id = source.encryption_key_id
        same_owner_copy = store_vault_credential(owner: owner, secret: "#{vault_secret}-copy")

        source.update_columns(encrypted_payload: tamper_ciphertext(original_ciphertext))
        tampered = probe_vault(owner: owner, credential: source)
        expect(tampered[:yielded]).to be(false)
        expect(tampered[:error]).to be_a(described_class::AuthenticationFailure)
        expect(tampered[:error].message).not_to include(source.encrypted_payload)
        expect(source.reload.last_used_at).to be_nil

        same_owner_copy.update_columns(encrypted_payload: original_ciphertext, encryption_key_id: original_key_id)
        copied_binding = probe_vault(owner: owner, credential: same_owner_copy)
        expect(copied_binding[:yielded]).to be(false)
        expect(copied_binding[:error]).to be_a(described_class::AuthenticationFailure)

        stolen = store_vault_credential(owner: owner, secret: "#{vault_secret}-stolen")
        stolen.update_columns(user_id: other_user.id)
        copied_owner = probe_vault(owner: other_user, credential: stolen.reload)
        expect(copied_owner[:yielded]).to be(false)
        expect(copied_owner[:error]).to be_a(described_class::AuthenticationFailure)

        reclassified = store_vault_credential(owner: owner, secret: "#{vault_secret}-reclassified")
        reclassified.update_columns(provider: 'libre', purpose: 'search', credential_type: 'oauth')
        copied_classification = probe_vault(owner: owner, credential: reclassified.reload, provider: 'libre', purpose: 'search', credential_type: 'oauth')
        expect(copied_classification[:yielded]).to be(false)
        expect(copied_classification[:error]).to be_a(described_class::AuthenticationFailure)
        expect(reclassified.reload.last_used_at).to be_nil
      end
    end

    it 'fails closed when the row names a key id that is not in the ring' do
      with_vault_keyring do
        record = store_vault_credential(owner: owner)
        record.update_columns(encryption_key_id: 'missing')
        probe = probe_vault(owner: owner, credential: record)

        expect(probe[:yielded]).to be(false)
        expect(probe[:error]).to be_a(described_class::UnknownKey)
        expect(probe[:error].message).not_to include(vault_secret)
        expect(record.reload.last_used_at).to be_nil
      end
    end

    it 'fails closed when key material disappears after the row was stored' do
      record = with_vault_keyring { store_vault_credential(owner: owner) }

      with_vault_keyring(primary: '', keys: '') do
        probe = probe_vault(owner: owner, credential: record)
        expect(probe[:yielded]).to be(false)
        expect(probe[:error]).to be_a(described_class::ConfigurationError)
        expect(record.reload.last_used_at).to be_nil
      end
    end
  end

  describe 'key ids and rotation' do
    it 'decrypts a row sealed with an old key and encrypts new rows with the primary key only' do
      record = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: owner) }
      expect(record.encryption_key_id).to eq('v1')

      with_vault_keyring(primary: 'v2') do
        probe = probe_vault(owner: owner, credential: record)
        expect(probe[:yielded]).to be(true)
        expect(probe[:result]).to eq(vault_secret)
        expect(record.reload.encryption_key_id).to eq('v1')

        fresh = store_vault_credential(owner: owner, secret: "#{vault_secret}-fresh")
        expect(fresh.encryption_key_id).to eq('v2')
      end
    end

    it 'rotates onto the primary key, keeps the payload, and does not add a plaintext attribute' do
      record = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: owner) }
      columns_before = UserExternalCredential.column_names
      ciphertext_before = record.encrypted_payload
      binding_before = record.binding_id

      with_vault_keyring(primary: 'v2') do
        report = described_class.rotate_encryption_keys!
        record.reload

        expect(report.examined).to eq(1)
        expect(report.rotated).to eq(1)
        expect(report.failures).to be_empty
        expect(report.dry_run).to be(false)
        expect(record.encryption_key_id).to eq('v2')
        expect(record.binding_id).to eq(binding_before)
        expect(record.encrypted_payload).not_to eq(ciphertext_before)
        expect(record.encrypted_payload).not_to include(vault_secret)
        expect(record.last_used_at).to be_nil
        expect(UserExternalCredential.column_names).to eq(columns_before)
        expect(record.attributes.keys).not_to include('api_key', 'secret', 'credentials', 'payload')
        expect(persisted_row_text(record)).not_to include(vault_secret)

        probe = probe_vault(owner: owner, credential: record)
        expect(probe[:result]).to eq(vault_secret)
      end
    end

    it 'reports a dry run without writing and leaves an unreadable row in place' do
      readable = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: owner) }
      broken = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: owner, secret: "#{vault_secret}-broken") }
      broken.update_columns(encrypted_payload: tamper_ciphertext(broken.encrypted_payload))
      original_ciphertext = readable.encrypted_payload
      broken_ciphertext = broken.encrypted_payload

      with_vault_keyring(primary: 'v2') do
        preview = nil
        expect { described_class.rotate_encryption_keys!(dry_run: true) }.to raise_error(described_class::RotationError) { |error| preview = error.report }
        expect(preview.dry_run).to be(true)
        expect(preview.rotated).to eq(0)
        expect(preview.would_rotate).to eq(1)
        expect(preview.failures.map { |failure| failure[:id] }).to eq([broken.id])
        expect(preview.failures.first[:error_class]).to eq('UserCredentialVault::AuthenticationFailure')
        expect(readable.reload.encrypted_payload).to eq(original_ciphertext)
        expect(readable.encryption_key_id).to eq('v1')
        expect(broken.reload.encrypted_payload).to eq(broken_ciphertext)

        expect { described_class.rotate_encryption_keys! }.to raise_error(described_class::RotationError) { |error|
          expect(error.message).not_to include(vault_secret)
          expect(error.message).not_to include(broken_ciphertext)
          expect(error.report.rotated).to eq(1)
          expect(error.report.failures.map { |failure| failure[:id] }).to eq([broken.id])
        }
      end

      expect(UserExternalCredential.find(broken.id).encrypted_payload).to eq(broken_ciphertext)
      expect(readable.reload.encryption_key_id).to eq('v2')
      expect(probe_vault_with_keyring(readable)).to eq(vault_secret)
    end

    it 'does not rewrite a row that is already on the primary key' do
      with_vault_keyring(primary: 'v2') do
        record = store_vault_credential(owner: owner)
        ciphertext = record.encrypted_payload
        report = described_class.rotate_encryption_keys!

        expect(report.already_primary).to eq(1)
        expect(report.rotated).to eq(0)
        expect(record.reload.encrypted_payload).to eq(ciphertext)
      end
    end
  end

  describe 'replace, revoke, and delete' do
    it 'replaces under a new binding id and keeps revoked and expiry state unless explicitly changed' do
      record = nil
      expires_at = 2.days.from_now.change(usec: 0)
      with_vault_keyring(primary: 'v1') do
        record = store_vault_credential(owner: owner, expires_at: expires_at)
        described_class.revoke!(owner: owner, credential: record)
      end

      old_binding_id = record.binding_id
      revoked_at = record.revoked_at

      with_vault_keyring(primary: 'v2') do
        replaced = replace_vault_credential(owner: owner, credential: record, secret: "#{vault_secret}-replaced")

        expect(replaced.binding_id).not_to eq(old_binding_id)
        expect(replaced.encryption_key_id).to eq('v2')
        expect(replaced.revoked_at).to be_within(1.second).of(revoked_at)
        expect(replaced.expires_at).to eq(expires_at)
        expect(replaced.encrypted_payload).not_to include("#{vault_secret}-replaced")

        denied = probe_vault(owner: owner, credential: replaced)
        expect(denied[:yielded]).to be(false)
        expect(denied[:error]).to be_a(described_class::Revoked)

        reactivated = replace_vault_credential(
          owner: owner,
          credential: replaced,
          secret: "#{vault_secret}-reactivated",
          revoked_at: nil,
        )
        expect(reactivated.revoked_at).to be_nil
        expect(reactivated.expires_at).to eq(expires_at)
        expect(probe_vault(owner: owner, credential: reactivated)[:result]).to eq("#{vault_secret}-reactivated")
      end
    end

    it 'does not authenticate the previous ciphertext under the replacement binding id' do
      old_ciphertext = nil
      old_key_id = nil
      record = nil

      with_vault_keyring do
        record = store_vault_credential(owner: owner)
        old_ciphertext = record.encrypted_payload
        old_key_id = record.encryption_key_id
        old_binding_id = record.binding_id
        replaced = replace_vault_credential(owner: owner, credential: record, secret: "#{vault_secret}-new")
        expect(replaced.binding_id).not_to eq(old_binding_id)

        replaced.update_columns(encrypted_payload: old_ciphertext, encryption_key_id: old_key_id)
        probe = probe_vault(owner: owner, credential: replaced.reload)
        expect(probe[:yielded]).to be(false)
        expect(probe[:error]).to be_a(described_class::AuthenticationFailure)
        expect(replaced.reload.last_used_at).to be_nil
      end
    end

    it 'hard-deletes a credential without decrypting it' do
      record = with_vault_keyring { store_vault_credential(owner: owner) }
      with_vault_keyring(primary: '', keys: '') do
        described_class.delete!(owner: owner, credential: record)
      end

      expect(UserExternalCredential.where(id: record.id)).to be_empty
    end

    it 'refuses to replace another user\'s credential' do
      record = with_vault_keyring { store_vault_credential(owner: owner) }
      with_vault_keyring do
        expect do
          replace_vault_credential(owner: other_user, credential: record, secret: "#{vault_secret}-nope")
        end.to raise_error(described_class::OwnerMismatch)
      end

      expect(record.reload.encrypted_payload).not_to include("#{vault_secret}-nope")
    end
  end

  describe 'last_used_at' do
    it 'updates last_used_at only when the credential is actually yielded' do
      with_vault_keyring do
        record = store_vault_credential(owner: owner)
        expect(record.last_used_at).to be_nil

        probe_vault(owner: other_user, credential: record)
        expect(record.reload.last_used_at).to be_nil

        expect do
          described_class.with_credential(
            owner: owner,
            credential: record,
            provider: 'deepl',
            purpose: 'translation',
            credential_type: 'api_key',
          ) { raise 'caller failed after receiving the credential' }
        end.to raise_error(RuntimeError, 'caller failed after receiving the credential')

        expect(record.reload.last_used_at).to be_present
      end
    end
  end

  describe 'parameter logging' do
    it 'redacts credential parameter names without redacting ordinary fields' do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(
        username: 'alice',
        locale: 'en',
        provider: 'deepl',
        purpose: 'translation',
        note: 'hello',
        credential: vault_secret,
        credential_payload: vault_secret,
        credential_type: 'api_key',
        api_key: vault_secret,
        access_token: vault_secret,
        refresh_token: vault_secret,
        client_secret: vault_secret,
        secret: vault_secret,
        encrypted_payload: 'ciphertext-blob',
      )

      expect(filtered[:username]).to eq('alice')
      expect(filtered[:locale]).to eq('en')
      expect(filtered[:provider]).to eq('deepl')
      expect(filtered[:purpose]).to eq('translation')
      expect(filtered[:note]).to eq('hello')

      %i(credential credential_payload credential_type api_key access_token refresh_token client_secret secret encrypted_payload).each do |key|
        expect(filtered[key]).to eq('[FILTERED]')
      end
      expect(filtered.to_s).not_to include(vault_secret)
    end
  end

  def probe_vault_with_keyring(record)
    with_vault_keyring { probe_vault(owner: owner, credential: record)[:result] }
  end
end
