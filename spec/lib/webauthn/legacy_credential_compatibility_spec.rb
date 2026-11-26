# frozen_string_literal: true

require 'rails_helper'

# Credential id, COSE public key, sign count, and user handle below were
# produced by webauthn 2.5.2's FakeClient. The fixture contains no private key.
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
