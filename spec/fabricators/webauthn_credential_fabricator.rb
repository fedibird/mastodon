Fabricator(:webauthn_credential) do
  user_id { Fabricate(:user).id }
  external_id { Base64.urlsafe_encode64(SecureRandom.random_bytes(16)) }
  # Placeholder only. OpenSSL 3 rejects EC#generate_key after the openssl gem loads,
  # and ceremony specs use WebAuthn::FakeClient keys instead of this value.
  public_key { 'webauthn-test-public-key' }
  nickname 'USB key'
  sign_count 0
end
