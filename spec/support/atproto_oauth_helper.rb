# frozen_string_literal: true

module AtprotoOauthHelper
  PUBLIC_IP = '93.184.216.34'
  DID = 'did:plc:abcdefghijklmnopqrstuvwx'
  OTHER_DID = 'did:plc:zyxwvutsrqponmlkjihgfedc'
  WEB_DID = 'did:web:self.example'
  HANDLE = 'alice.example'
  PDS_HOST = 'pds.example'
  ISSUER_HOST = 'entry.example'
  REFRESH_TOKEN = 'refresh-token-SENTINEL-935-not-real'
  ACCESS_TOKEN = 'access-token-SENTINEL-246-not-real'
  BROWSER = 'browser-binding-token-for-atproto-tests'

  class MapDns
    def initialize(addresses, txt)
      @addresses = addresses.transform_keys { |key| key.to_s.downcase }
      @txt = txt.transform_keys { |key| key.to_s.downcase }
    end

    def addresses(host)
      @addresses.fetch(host.to_s.downcase, [PUBLIC_IP]).map { |value| IPAddr.new(value) }
    end

    def txt(name)
      @txt.fetch(name.to_s.downcase, [])
    end
  end

  def atproto_pds
    "https://#{PDS_HOST}"
  end

  def atproto_issuer
    "https://#{ISSUER_HOST}"
  end

  def enable_atproto!(*users)
    Setting.external_bridge_atproto = true
    Setting.external_bridge_atproto_testers = users.flatten.compact.map { |user| user.id.to_i }.join(',')
  end

  def with_atproto_client
    key = OpenSSL::PKey::EC.generate('prime256v1')
    ClimateControl.modify(
      ATPROTO_OAUTH_SIGNING_KEY: key.to_pem,
      USER_EXTERNAL_CREDENTIAL_KEYS: vault_keyring_string,
      USER_EXTERNAL_CREDENTIAL_PRIMARY_KEY: 'v2',
    ) { yield key }
  end

  def atproto_dns(addresses: {}, txt: {})
    MapDns.new(addresses, txt)
  end

  def atproto_metadata(issuer: atproto_issuer, scopes: ExternalBridge::Atproto::Scopes::GRANULAR)
    {
      'issuer' => issuer,
      'authorization_endpoint' => "#{issuer}/oauth/authorize",
      'token_endpoint' => "#{issuer}/oauth/token",
      'pushed_authorization_request_endpoint' => "#{issuer}/oauth/par",
      'revocation_endpoint' => "#{issuer}/oauth/revoke",
      'scopes_supported' => scopes,
      'require_pushed_authorization_requests' => true,
      'client_id_metadata_document_supported' => true,
      'authorization_response_iss_parameter_supported' => true,
      'response_types_supported' => ['code'],
      'grant_types_supported' => %w(authorization_code refresh_token),
      'code_challenge_methods_supported' => ['S256'],
      'token_endpoint_auth_methods_supported' => ['private_key_jwt'],
      'token_endpoint_auth_signing_alg_values_supported' => ['ES256'],
      'dpop_signing_alg_values_supported' => ['ES256'],
    }
  end

  def atproto_document(did: DID, handle: HANDLE, pds: atproto_pds)
    {
      'id' => did,
      'alsoKnownAs' => ["at://#{handle}"],
      'service' => [
        {
          'id' => '#atproto_pds',
          'type' => 'AtprotoPersonalDataServer',
          'serviceEndpoint' => pds,
        },
      ],
    }
  end

  def atproto_json(body, status: 200, nonce: 'server-nonce-1')
    {
      status: status,
      headers: { 'Content-Type' => 'application/json', 'DPoP-Nonce' => nonce },
      body: body.is_a?(String) ? body : JSON.generate(body),
    }
  end

  def atproto_tokens(did: DID, scope: nil, refresh: REFRESH_TOKEN, access: ACCESS_TOKEN, expires_in: 300)
    {
      'token_type' => 'DPoP',
      'sub' => did,
      'scope' => scope || ExternalBridge::Atproto::Scopes::GRANULAR.join(' '),
      'expires_in' => expires_in,
      'refresh_token' => refresh,
      'access_token' => access,
    }
  end

  World = Struct.new(:dns, :bodies, keyword_init: true)

  def install_atproto_world!(did: DID, handle: HANDLE, pds: atproto_pds, issuer: atproto_issuer, document: nil, protected_body: nil, metadata: nil, txt: nil, addresses: nil, protected_status: 200, handle_http: nil, metadata_response: nil, par_response: nil)
    dns = atproto_dns(
      addresses: addresses || {},
      txt: txt || { "_atproto.#{handle}" => ["did=#{did}"] },
    )
    bodies = {
      document: document || atproto_document(did: did, handle: handle, pds: pds),
      protected: protected_body || { 'authorization_servers' => [issuer] },
      protected_status: protected_status,
      metadata: metadata || atproto_metadata(issuer: issuer),
      token: atproto_tokens(did: did),
      token_handler: nil,
      par_handler: nil,
      revoke_response: nil,
    }
    stub_request(:get, "https://plc.directory/#{did}").to_return { atproto_json(bodies[:document]) }
    stub_request(:get, %r{\Ahttps://[^/]+/\.well-known/did\.json\z}).to_return { atproto_json(bodies[:document]) }
    stub_request(:get, %r{\Ahttps://[^/]+/\.well-known/atproto-did\z}).to_return(handle_http || { status: 404, body: '' })
    stub_request(:get, "#{pds}/.well-known/oauth-protected-resource").to_return { atproto_json(bodies[:protected], status: bodies[:protected_status]) }
    if metadata_response
      stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server").to_return(metadata_response)
    else
      stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server").to_return { atproto_json(bodies[:metadata]) }
    end
    stub_request(:post, "#{issuer}/oauth/par").to_return do |request|
      bodies[:par_handler] ? bodies[:par_handler].call(request) : (par_response || atproto_json({ 'request_uri' => 'urn:ietf:params:oauth:request_uri:one', 'expires_in' => 60 }))
    end
    stub_request(:post, "#{issuer}/oauth/token").to_return do |request|
      bodies[:token_handler] ? bodies[:token_handler].call(request) : atproto_json(bodies[:token])
    end
    stub_request(:post, "#{issuer}/oauth/revoke").to_return { bodies[:revoke_response] || atproto_json({}) }
    World.new(dns: dns, bodies: bodies)
  end

  def use_atproto_dns!(world)
    allow(ExternalBridge::Atproto::Dns).to receive(:live).and_return(world.dns)
    world
  end

  def start_atproto!(user:, identifier:, dns:, consent: false, browser: BROWSER)
    captured = []
    allow(SecureRandom).to receive(:urlsafe_base64).and_wrap_original do |method, *args, **kwargs|
      value = method.call(*args, **kwargs)
      captured << value if args == [32]
      value
    end
    url = ExternalBridge::Atproto::Authorize.call(
      user: user,
      identifier: identifier,
      accept_transition_generic: consent,
      browser_token: browser,
      dns: dns,
    )
    { url: url, state: captured.last, verifier: captured[-2], browser: browser }
  end

  def finish_atproto!(user:, state:, browser: BROWSER, iss: atproto_issuer, code: 'auth-code-1', dns: nil, error: nil)
    ExternalBridge::Atproto::Callback.call(
      user: user,
      browser_token: browser,
      state: state.to_s,
      iss: iss.to_s,
      code: code.to_s,
      provider_error: error.to_s,
      dns: dns,
    )
  end

  def connect_atproto!(user:, identifier: HANDLE, world: nil, iss: atproto_issuer)
    world ||= install_atproto_world!
    started = start_atproto!(user: user, identifier: identifier, dns: world.dns)
    identity = finish_atproto!(user: user, state: started[:state], browser: started[:browser], iss: iss, dns: world.dns)
    { identity: identity, world: world, started: started }
  end

  def atproto_error
    yield
    nil
  rescue ExternalBridge::Error => e
    e
  end

  def atproto_exchanges
    exchanges = []
    WebMock::RequestRegistry.instance.requested_signatures.each { |signature, _times| exchanges << signature }
    exchanges
  end

  def reset_atproto_exchanges!
    WebMock::RequestRegistry.instance.reset!
  end

  def exchanges_carrying(*needles)
    atproto_exchanges.select do |exchange|
      blob = "#{exchange.body} #{exchange.headers}"
      needles.any? { |needle| blob.include?(needle) }
    end
  end

  def expect_secret_absent!(*needles)
    blob = [
      ExternalIdentity.all.map { |row| row.attributes.except('id', 'created_at', 'updated_at') }.to_json,
      ExternalOauthAttempt.all.map { |row| row.attributes.except('encrypted_secrets') }.to_json,
      UserExternalCredential.all.map { |row| persisted_row_text(row) }.join("\n"),
      ExternalOauthAttempt.pluck(:encrypted_secrets).join("\n"),
    ].join("\n")
    needles.each { |needle| expect(blob).not_to include(needle) }
  end

  def decode_jwt(token)
    header, payload, signature = token.split('.')
    {
      header: JSON.parse(Base64.urlsafe_decode64(pad_base64(header))),
      payload: JSON.parse(Base64.urlsafe_decode64(pad_base64(payload))),
      signature: Base64.urlsafe_decode64(pad_base64(signature)),
    }
  end

  def pad_base64(value)
    value.to_s + ('=' * ((4 - (value.to_s.length % 4)) % 4))
  end

  def jose_signed?(token, key)
    decoded = decode_jwt(token)
    raw = decoded[:signature]
    r = raw.byteslice(0, 32).unpack1('H*').to_i(16)
    s = raw.byteslice(32, 32).unpack1('H*').to_i(16)
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s)]).to_der
    header, payload, = token.split('.')
    key.verify(OpenSSL::Digest::SHA256.new, der, "#{header}.#{payload}")
  end
end

RSpec.configure do |config|
  config.include AtprotoOauthHelper
end
