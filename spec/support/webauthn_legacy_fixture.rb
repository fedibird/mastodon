# frozen_string_literal: true

module WebauthnLegacyFixture
  FIXTURE_PATH = 'spec/fixtures/webauthn/credential_registered_with_2_5_2.json'

  module_function

  def cose_public_key
    JSON.parse(Rails.root.join(FIXTURE_PATH).read).dig('stored_credential', 'public_key')
  end

  def webauthn_legacy_fixture
    @webauthn_legacy_fixture ||= JSON.parse(Rails.root.join(FIXTURE_PATH).read)
  end

  def with_legacy_webauthn_origin
    original_origins = WebAuthn.configuration.allowed_origins.dup
    WebAuthn.configuration.allowed_origins = [webauthn_legacy_fixture.fetch('origin')]
    yield webauthn_legacy_fixture
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
  end
end
