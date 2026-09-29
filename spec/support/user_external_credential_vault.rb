# frozen_string_literal: true

module UserExternalCredentialVaultHelper
  def vault_secret
    @vault_secret ||= "test-only-not-a-real-credential-#{SecureRandom.hex(8)}"
  end

  def vault_key_material
    @vault_key_material ||= {
      'v1' => Base64.strict_encode64(SecureRandom.random_bytes(32)),
      'v2' => Base64.strict_encode64(SecureRandom.random_bytes(32)),
    }
  end

  def vault_keyring_string(ids = %w(v2 v1))
    ids.map { |id| "#{id}:#{vault_key_material.fetch(id)}" }.join(',')
  end

  def with_vault_keyring(primary: 'v2', keys: :default)
    serialized = keys == :default ? vault_keyring_string : keys
    ClimateControl.modify(
      USER_EXTERNAL_CREDENTIAL_KEYS: serialized,
      USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY: primary,
    ) { yield }
  end

  def store_vault_credential(owner:, secret: vault_secret, provider: 'deepl', purpose: 'translation', credential_type: 'api_key', credentials: nil, **options)
    UserCredentialVault.store!(
      **{
        owner: owner,
        provider: provider,
        purpose: purpose,
        credential_type: credential_type,
        credentials: credentials || { 'api_key' => secret },
      }.merge(options),
    )
  end

  def replace_vault_credential(owner:, credential:, secret:, **options)
    UserCredentialVault.replace!(
      **{
        owner: owner,
        credential: credential,
        provider: credential.provider,
        purpose: credential.purpose,
        credential_type: credential.credential_type,
        credentials: { 'api_key' => secret },
      }.merge(options),
    )
  end

  # Returns yielded, result, and error without letting the vault exception escape.
  # result is a duplicate of the api_key when the block runs.
  def probe_vault(owner:, credential:, provider: nil, purpose: nil, credential_type: nil)
    yielded = false
    result = nil
    error = nil

    begin
      result = UserCredentialVault.with_credential(
        owner: owner,
        credential: credential,
        provider: provider || credential.provider,
        purpose: purpose || credential.purpose,
        credential_type: credential_type || credential.credential_type,
      ) do |payload|
        yielded = true
        payload.fetch('credentials').fetch('api_key').dup
      end
    rescue UserCredentialVault::Error => e
      error = e
    end

    { yielded: yielded, result: result, error: error }
  end

  def persisted_row_text(record)
    quoted_id = UserExternalCredential.connection.quote(record.id)
    row = UserExternalCredential.connection.select_one("SELECT * FROM user_external_credentials WHERE id = #{quoted_id}")
    row.values.map(&:to_s).join("\n")
  end

  def tamper_ciphertext(value)
    mutated = value.dup
    index = mutated.index(/[A-Za-z]/)
    mutated[index] = mutated[index] == 'A' ? 'B' : 'A'
    mutated
  end
end

RSpec.configure do |config|
  config.include UserExternalCredentialVaultHelper
end
