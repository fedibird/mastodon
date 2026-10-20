# frozen_string_literal: true

require 'rails_helper'

describe ExternalIdentity do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }

  def identity_for(owner, credential: nil)
    described_class.new(
      user: owner,
      provider: 'bluesky',
      subject: AtprotoOauthHelper::DID,
      issuer: 'https://entry.example',
      resource_origin: 'https://pds.example',
      token_endpoint: 'https://entry.example/oauth/token',
      status: 'connected',
      terms_state: 'approved',
      granted_scopes: ['atproto'],
      credential: credential,
    )
  end

  it 'rejects a credential owned by someone else or stored for another purpose' do
    with_vault_keyring do
      foreign = store_vault_credential(owner: other)
      own_translation = store_vault_credential(owner: user)

      expect(identity_for(user, credential: foreign)).not_to be_valid
      expect(identity_for(user, credential: own_translation)).not_to be_valid
      expect(identity_for(user)).to be_valid
    end
  end

  it 'accepts only safe error codes and omits attempt ciphertext from JSON' do
    row = identity_for(user)
    row.last_error_code = 'provider said the token is abc'
    expect(row).not_to be_valid
    row.last_error_code = 'issuer_mismatch'
    expect(row).to be_valid

    with_vault_keyring do
      ciphertext, key_id = ExternalBridge::Atproto::AttemptBox.encrypt(
        user_id: user.id,
        binding_id: SecureRandom.uuid,
        secrets: { 'pkce_verifier' => 'verifier-SENTINEL', 'dpop_private_key' => 'not-a-real-pem' },
      )
      attempt = ExternalOauthAttempt.create!(
        user: user,
        provider: 'bluesky',
        state_digest: Digest::SHA256.hexdigest('state'),
        browser_binding_digest: Digest::SHA256.hexdigest('browser'),
        input_kind: 'handle',
        issuer: 'https://entry.example',
        authorization_endpoint: 'https://entry.example/oauth/authorize',
        token_endpoint: 'https://entry.example/oauth/token',
        par_endpoint: 'https://entry.example/oauth/par',
        redirect_uri: 'https://cb6e6126.ngrok.io/settings/external_services/bluesky/callback',
        requested_scopes: 'atproto',
        binding_id: SecureRandom.uuid,
        encrypted_secrets: ciphertext,
        encryption_key_id: key_id,
        expires_at: 10.minutes.from_now,
      )
      expect(attempt.to_json).not_to include('verifier-SENTINEL')
      expect(attempt.to_json).not_to include(ciphertext)
      expect(attempt.inspect).not_to include(ciphertext)
    end
  end

  it 'rolls the migration back inside the test transaction' do
    require Rails.root.join('db/migrate/20261020130000_create_external_atproto_identities')
    expect(described_class.connection.table_exists?(:external_identities)).to be(true)
    ActiveRecord::Migration.suppress_messages do
      CreateExternalAtprotoIdentities.migrate(:down)
      expect(described_class.connection.table_exists?(:external_identities)).to be(false)
      expect(described_class.connection.table_exists?(:external_oauth_attempts)).to be(false)
      CreateExternalAtprotoIdentities.migrate(:up)
    end
    expect(described_class.connection.table_exists?(:external_identities)).to be(true)
  end
end
