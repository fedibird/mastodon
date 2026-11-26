# frozen_string_literal: true

require 'rails_helper'
require 'webauthn/fake_client'

# Public fixtures only. No private keys.
#
# ES256 (`credential_registered_with_2_5_2.json`):
#   webauthn 2.5.2 FakeClient, origin http://localhost:3000, cose 1.3.1 / cbor 0.5.10.1.
#   One assertion includes clientData.tokenBinding status "supported".
# RS256 (`credential_rs256_registered_with_2_5_2.json`):
#   same 2.5.2 FakeAuthenticator, with new_credential returning an RSA-2048 key.
#   That stack serializes the public key as COSE alg -257 and signs PKCS#1 SHA-256.
# PS256 (`credential_ps256_registered_with_2_5_2.json`):
#   2.5.2 FakeAuthenticator always labels RSA keys as RS256, so this fixture was
#   built on that same cose 1.3.1: public COSE RSA key alg -37, RSA-PSS SHA-256
#   with salt_length :max (the signer webauthn 2.5.2 verifies).
#
# cose 1.4.0 rejects a PS256 operation when the COSE key's alg is present and is
# not -37. WebAuthn selects the verifier from that alg, so a stored RS256 key
# (-257) and a stored PS256 key (-37) still reach the matching verifier.
# RS256's valid_key? is unchanged. These fixtures cover that path.
#
# Rollback check, not part of the app bundle: install webauthn 2.5.2 with
# cbor 0.5.10.1, cose 1.3.1, openssl 3.0.3, jwt 2.10.2, safety_net_attestation 0.4.0,
# tpm-key_attestation 0.11.0, and bindata 2.5.1. Configure origin to the fixture
# origin and verify the stored public key against the assertion with Integer(sign_count).
RSpec.describe 'WebAuthn credentials registered with 2.5.2' do
  include WebauthnLegacyFixture

  def verify_assertion(assertion, public_key:, sign_count:)
    WebAuthn::Credential.from_get(assertion.fetch('credential')).verify(
      assertion.fetch('challenge'),
      public_key: public_key,
      sign_count: sign_count
    )
  end

  it 'verifies the original registration and stores the same public credential' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      registration = fixture.fetch('registration')
      credential = WebAuthn::Credential.from_create(registration.fetch('credential'))

      expect(credential.verify(registration.fetch('challenge'))).to be(true)
      expect(credential.id).to eq(stored.fetch('external_id'))
      expect(credential.public_key).to eq(stored.fetch('public_key'))
      expect(credential.sign_count).to eq(stored.fetch('sign_count'))
    end
  end

  it 'verifies an assertion against the stored public key, sign count, and user handle' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('assertion')
      credential = WebAuthn::Credential.from_get(assertion.fetch('credential'))

      expect(
        credential.verify(
          assertion.fetch('challenge'),
          public_key: stored.fetch('public_key'),
          sign_count: stored.fetch('sign_count')
        )
      ).to be(true)
      expect(credential.sign_count).to eq(assertion.fetch('sign_count'))
      expect(credential.user_handle).to eq(fixture.fetch('user_handle'))
      expect(credential.id).to eq(stored.fetch('external_id'))
    end
  end

  it 'still verifies clientData that contains a tokenBinding field' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('token_binding_assertion')
      client_data = JSON.parse(
        WebAuthn.configuration.encoder.decode(assertion.dig('credential', 'response', 'clientDataJSON'))
      )

      expect(client_data.dig('tokenBinding', 'status')).to eq('supported')
      expect(verify_assertion(assertion, public_key: stored.fetch('public_key'), sign_count: stored.fetch('sign_count'))).to be(true)
      expect(WebAuthn::Credential.from_get(assertion.fetch('credential')).user_handle).to eq(fixture.fetch('user_handle'))
    end
  end

  it 'deserializes the stored COSE key as ES256' do
    stored = webauthn_legacy_fixture.fetch('stored_credential')
    raw_public_key = WebAuthn.configuration.encoder.decode(stored.fetch('public_key'))

    expect(WebAuthn::PublicKey.deserialize(raw_public_key).alg).to eq(-7)
  end

  it 'rejects a mismatched challenge without accepting the assertion' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('assertion')

      expect do
        WebAuthn::Credential.from_get(assertion.fetch('credential')).verify(
          WebAuthn::Credential.options_for_get.challenge,
          public_key: stored.fetch('public_key'),
          sign_count: stored.fetch('sign_count')
        )
      end.to raise_error(WebAuthn::ChallengeVerificationError)
    end
  end

  it 'rejects a different origin and a different RP ID' do
    fixture = webauthn_legacy_fixture
    stored = fixture.fetch('stored_credential')
    assertion = fixture.fetch('assertion')
    original_origins = WebAuthn.configuration.allowed_origins.dup
    original_rp_id = WebAuthn.configuration.rp_id

    WebAuthn.configuration.allowed_origins = ['https://evil.example']
    expect do
      verify_assertion(assertion, public_key: stored.fetch('public_key'), sign_count: stored.fetch('sign_count'))
    end.to raise_error(WebAuthn::OriginVerificationError)

    WebAuthn.configuration.allowed_origins = [fixture.fetch('origin')]
    WebAuthn.configuration.rp_id = 'evil.example'
    expect do
      verify_assertion(assertion, public_key: stored.fetch('public_key'), sign_count: stored.fetch('sign_count'))
    end.to raise_error(WebAuthn::RpIdVerificationError)
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
    WebAuthn.configuration.rp_id = original_rp_id
  end

  it 'rejects a sign count that does not increase and a signature from another key' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('assertion')
      other_client = WebAuthn::FakeClient.new(fixture.fetch('origin'))
      other_public_key = WebAuthn::Credential.from_create(other_client.create).public_key

      expect do
        verify_assertion(assertion, public_key: stored.fetch('public_key'), sign_count: assertion.fetch('sign_count'))
      end.to raise_error(WebAuthn::SignCountVerificationError)

      expect do
        verify_assertion(assertion, public_key: other_public_key, sign_count: stored.fetch('sign_count'))
      end.to raise_error(WebAuthn::SignatureVerificationError)
    end
  end

  it 'passes an existing user handle through unchanged' do
    user_handle = webauthn_legacy_fixture.fetch('user_handle')
    options = WebAuthn::Credential.options_for_create(
      user: { id: user_handle, name: 'alice', display_name: 'alice' }
    )

    expect(options.as_json.dig('user', 'id') || options.as_json.dig(:user, :id)).to eq(user_handle)
  end

  {
    'RS256' => [-257, 'spec/fixtures/webauthn/credential_rs256_registered_with_2_5_2.json'],
    'PS256' => [-37, 'spec/fixtures/webauthn/credential_ps256_registered_with_2_5_2.json'],
  }.each do |algorithm, (cose_alg, path)|
    it "verifies a #{algorithm} public key produced with webauthn 2.5.2 and cose 1.3.1" do
      fixture = JSON.parse(Rails.root.join(path).read)
      original_origins = WebAuthn.configuration.allowed_origins.dup
      WebAuthn.configuration.allowed_origins = [fixture.fetch('origin')]
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('assertion')
      raw_public_key = WebAuthn.configuration.encoder.decode(stored.fetch('public_key'))

      expect(CBOR.decode(raw_public_key)).not_to have_key(-3)
      expect(WebAuthn::PublicKey.deserialize(raw_public_key).alg).to eq(cose_alg)
      expect(fixture.fetch('generator')).to eq('webauthn-2.5.2')
      expect(fixture.fetch('cose')).to eq('1.3.1')
      expect(
        verify_assertion(assertion, public_key: stored.fetch('public_key'), sign_count: Integer(stored.fetch('sign_count')))
      ).to be(true)
      expect(WebAuthn::Credential.from_get(assertion.fetch('credential')).user_handle).to eq(fixture.fetch('user_handle'))
    ensure
      WebAuthn.configuration.allowed_origins = original_origins
    end
  end

  it 'raises a WebAuthn error when the challenge is missing' do
    with_legacy_webauthn_origin do |fixture|
      stored = fixture.fetch('stored_credential')
      assertion = fixture.fetch('assertion')

      expect do
        WebAuthn::Credential.from_get(assertion.fetch('credential')).verify(
          nil,
          public_key: stored.fetch('public_key'),
          sign_count: stored.fetch('sign_count')
        )
      end.to raise_error(WebAuthn::PublicKeyCredential::InvalidChallengeError)
    end
  end
end
