# frozen_string_literal: true

require 'rails_helper'

describe 'AT Protocol OAuth identity connection' do
  let(:user) { Fabricate(:user) }

  before { enable_atproto!(user) }

  def credential_for(identity)
    UserExternalCredential.find(identity.credential_id)
  end

  def revealed(identity, owner: user)
    revealed = nil
    UserCredentialVault.with_credential(owner: owner, credential: credential_for(identity), provider: 'bluesky', purpose: 'identity', credential_type: 'oauth_session') do |payload|
      revealed = payload.fetch('credentials')
      :ok
    end
    revealed
  end

  it 'stores one user-owned session after PAR, PKCE, and a DPoP token response' do
    world = nil
    identity = nil
    with_atproto_client do |key|
      world = install_atproto_world!
      connected = connect_atproto!(user: user, world: world)
      identity = connected.fetch(:identity)
      started = connected.fetch(:started)

      expect(started[:url]).to start_with("#{atproto_issuer}/oauth/authorize?")
      expect(started[:url]).to include('request_uri=')
      expect(started[:url]).not_to include(AtprotoOauthHelper::REFRESH_TOKEN)
      par = atproto_exchanges.find { |exchange| exchange.uri.path == '/oauth/par' }
      fields = Rack::Utils.parse_nested_query(par.body)
      expect(fields['code_challenge_method']).to eq('S256')
      expect(fields['code_challenge']).to eq(ExternalBridge::Atproto::Jwt.b64(Digest::SHA256.digest(started[:verifier])))
      expect(fields['scope']).to eq(ExternalBridge::Atproto::Scopes::GRANULAR.join(' '))
      expect(fields['redirect_uri']).to eq(ExternalBridge::Atproto::ClientDocument.redirect_uri)
      assertion = decode_jwt(fields['client_assertion'])
      expect(assertion[:payload]['aud']).to eq(atproto_issuer)
      expect(jose_signed?(fields['client_assertion'], key)).to be(true)
      dpop = decode_jwt(par.headers['Dpop'])
      expect(dpop[:header]['typ']).to eq('dpop+jwt')
      expect(dpop[:payload]['htu']).to eq("#{atproto_issuer}/oauth/par")
      expect(dpop[:header]['jwk']).not_to have_key('d')
    end

    expect(identity.user_id).to eq(user.id)
    expect(identity.provider).to eq('bluesky')
    expect(identity.subject).to eq(AtprotoOauthHelper::DID)
    expect(identity.handle).to eq(AtprotoOauthHelper::HANDLE)
    expect(identity.issuer).to eq(atproto_issuer)
    expect(identity.resource_origin).to eq(atproto_pds)
    expect(identity.status).to eq('connected')
    expect(identity.granted_scopes).to eq(ExternalBridge::Atproto::Scopes::GRANULAR)
    row = credential_for(identity)
    expect([row.provider, row.purpose, row.credential_type]).to eq(%w(bluesky identity oauth_session))
    expect(row.user_id).to eq(user.id)
    secrets = with_atproto_client { revealed(identity) }
    expect(secrets['refresh_token']).to eq(AtprotoOauthHelper::REFRESH_TOKEN)
    expect(secrets['issuer']).to eq(atproto_issuer)
    expect(secrets['dpop_private_key']).to include('PRIVATE KEY')
    expect_secret_absent!(AtprotoOauthHelper::REFRESH_TOKEN, AtprotoOauthHelper::ACCESS_TOKEN, secrets['dpop_private_key'])
    expect(ExternalOauthAttempt.count).to eq(0)
  end

  it 'links two DIDs for one user and keeps a second user on the same account out' do
    other = share_account_user(user.account)
    enable_atproto!(user, other)
    with_atproto_client do
      world = install_atproto_world!(txt: {
        "_atproto.#{AtprotoOauthHelper::HANDLE}" => ["did=#{AtprotoOauthHelper::DID}"],
        '_atproto.bob.example' => ["did=#{AtprotoOauthHelper::OTHER_DID}"],
      })
      first = connect_atproto!(user: user, world: world)
      stub_request(:get, "https://plc.directory/#{AtprotoOauthHelper::OTHER_DID}").to_return(
        atproto_json(atproto_document(did: AtprotoOauthHelper::OTHER_DID, handle: 'bob.example')),
      )
      world.bodies[:token] = atproto_tokens(did: AtprotoOauthHelper::OTHER_DID)
      second = connect_atproto!(user: user, identifier: 'bob.example', world: world)

      expect(user.external_identities.pluck(:subject)).to contain_exactly(AtprotoOauthHelper::DID, AtprotoOauthHelper::OTHER_DID)
      expect(ExternalServices::Bluesky.connections_for(other)).to be_empty
      expect(atproto_error { ExternalBridge::Atproto::Disconnect.call(user: other, identity_id: first[:identity].id, dns: world.dns) }.code).to eq('not_found')
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: other, identity_id: second[:identity].id, dns: world.dns) }.code).to eq('not_found')
      expect do
        UserCredentialVault.with_credential(owner: other, credential: credential_for(first[:identity]), provider: 'bluesky', purpose: 'identity', credential_type: 'oauth_session') { :ok }
      end.to raise_error(UserCredentialVault::OwnerMismatch)
      expect(first[:identity].reload.status).to eq('connected')
    end
  end

  it 'binds a hostname start only after the token sub resolves to that issuer' do
    with_atproto_client do
      world = install_atproto_world!
      connected = connect_atproto!(user: user, identifier: 'https://pds.example', world: world)

      expect(connected[:identity].subject).to eq(AtprotoOauthHelper::DID)
      expect(connected[:identity].resource_origin).to eq(atproto_pds)
      expect(connected[:identity].issuer).to eq(atproto_issuer)
      par = atproto_exchanges.find { |exchange| exchange.uri.path == '/oauth/par' }
      expect(Rack::Utils.parse_nested_query(par.body)).not_to have_key('login_hint')
    end
  end

  it 'discards tokens when sub, scopes, or the confirmed issuer do not match' do
    with_atproto_client do
      mismatched = install_atproto_world!
      mismatched.bodies[:token] = atproto_tokens(did: AtprotoOauthHelper::OTHER_DID)
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::DID, dns: mismatched.dns)
      error = atproto_error { finish_atproto!(user: user, state: started[:state], dns: mismatched.dns) }
      expect(error.code).to eq('authorization_rejected')
      expect(ExternalIdentity.count).to eq(0)
      expect(UserExternalCredential.where(credential_type: 'oauth_session')).to be_empty
      expect(exchanges_carrying(AtprotoOauthHelper::REFRESH_TOKEN).map { |exchange| exchange.uri.path }).to eq(['/oauth/revoke'])

      escalated = install_atproto_world!
      escalated.bodies[:token] = atproto_tokens(scope: "#{ExternalBridge::Atproto::Scopes::GRANULAR.join(' ')} transition:email")
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: escalated.dns)
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: escalated.dns) }.code).to eq('unsupported_scopes')
      expect(ExternalIdentity.count).to eq(0)

      moved = install_atproto_world!
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: moved.dns)
      moved.bodies[:protected] = { 'authorization_servers' => ['https://other.example'] }
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: moved.dns) }.code).to eq('issuer_mismatch')
      expect(ExternalIdentity.count).to eq(0)
      expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('other.example')
    end
  end

  it 'records a partial grant and rejects a callback with the wrong browser, issuer, or code' do
    with_atproto_client do
      partial = install_atproto_world!
      partial.bodies[:token] = atproto_tokens(scope: 'atproto')
      identity = connect_atproto!(user: user, world: partial).fetch(:identity)
      expect(identity.status).to eq('warning')
      expect(identity.last_error_code).to eq('partial_scopes')
      expect(identity.granted_scopes).to eq(['atproto'])

      world = install_atproto_world!
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      reset_atproto_exchanges!
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], browser: 'other-browser', dns: world.dns) }.code).to eq('state_rejected')
      expect(ExternalOauthAttempt.last.consumed_at).to be_nil
      expect(atproto_exchanges).to be_empty

      expect(atproto_error { finish_atproto!(user: user, state: started[:state], iss: 'https://evil.example', dns: world.dns) }.code).to eq('issuer_mismatch')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)
      expect(ExternalIdentity.where(subject: AtprotoOauthHelper::DID).where.not(id: identity.id)).to be_empty

      world.bodies[:token_handler] = ->(_request) { { status: 400, headers: { 'Content-Type' => 'application/json' }, body: '{"error":"invalid_grant","error_description":"leak-SENTINEL"}' } }
      fresh = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      error = atproto_error { finish_atproto!(user: user, state: fresh[:state], dns: world.dns) }
      expect(error.code).to eq('authorization_rejected')
      expect(error.message).not_to include('leak-SENTINEL')
    end
  end

  it 'consumes state once and keeps an older callback from replacing a newer session' do
    with_atproto_client do
      world = install_atproto_world!
      older = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      newer = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      world.bodies[:token] = atproto_tokens(refresh: 'refresh-newer-SENTINEL')
      winner = finish_atproto!(user: user, state: newer[:state], dns: world.dns)
      world.bodies[:token] = atproto_tokens(refresh: 'refresh-older-SENTINEL')
      expect(atproto_error { finish_atproto!(user: user, state: older[:state], dns: world.dns) }.code).to eq('stale_callback')
      expect(atproto_error { finish_atproto!(user: user, state: newer[:state], dns: world.dns) }.code).to eq('state_rejected')
      secrets = revealed(winner)
      expect(secrets['refresh_token']).to eq('refresh-newer-SENTINEL')
      expect(ExternalIdentity.where(user_id: user.id, subject: AtprotoOauthHelper::DID).count).to eq(1)
    end
  end

  it 'asks before requesting transition:generic and retries PAR with a new DPoP nonce' do
    with_atproto_client do
      scopes = %w(atproto transition:generic)
      refused = install_atproto_world!(metadata: atproto_metadata(scopes: scopes))
      expect(atproto_error { start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: refused.dns) }.code).to eq('unsupported_scopes')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)

      calls = []
      allowed = install_atproto_world!(metadata: atproto_metadata(scopes: scopes))
      allowed.bodies[:par_handler] = lambda do |request|
        calls << request.headers['Dpop']
        if calls.size == 1
          { status: 400, headers: { 'Content-Type' => 'application/json', 'DPoP-Nonce' => 'nonce-from-server' }, body: '{"error":"use_dpop_nonce"}' }
        else
          atproto_json({ 'request_uri' => 'urn:ietf:params:oauth:request_uri:two' })
        end
      end
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: allowed.dns, consent: true)
      fields = Rack::Utils.parse_nested_query(atproto_exchanges.reverse.find { |exchange| exchange.uri.path == '/oauth/par' }.body)
      expect(fields['scope']).to eq('atproto transition:generic')
      expect(calls.size).to eq(2)
      expect(decode_jwt(calls[0])[:payload]).not_to have_key('nonce')
      expect(decode_jwt(calls[1])[:payload]['nonce']).to eq('nonce-from-server')
      expect(decode_jwt(calls[0])[:payload]['jti']).not_to eq(decode_jwt(calls[1])[:payload]['jti'])
      expect(CGI.unescape(started[:url])).to include('urn:ietf:params:oauth:request_uri:two')
    end
  end

  it 'refreshes only at the bound issuer and replaces the rotating token' do
    with_atproto_client do
      world = install_atproto_world!
      world.bodies[:token] = atproto_tokens(expires_in: 90, refresh: 'refresh-before-SENTINEL')
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      world.bodies[:token] = atproto_tokens(expires_in: 300, refresh: 'refresh-after-SENTINEL')
      reset_atproto_exchanges!
      travel 5.minutes do
        refreshed = ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns)
        expect(refreshed.refresh_generation).to eq(1)
        expect(revealed(refreshed)['refresh_token']).to eq('refresh-after-SENTINEL')
      end
      posts = exchanges_carrying('refresh-before-SENTINEL')
      expect(posts.map { |exchange| [exchange.uri.host, exchange.uri.path] }).to eq([[AtprotoOauthHelper::ISSUER_HOST, '/oauth/token']])
      expect(exchanges_carrying('refresh-before-SENTINEL', 'refresh-after-SENTINEL').map { |exchange| exchange.uri.host }.uniq).to eq([AtprotoOauthHelper::ISSUER_HOST])
    end
  end

  it 'does not send a refresh token when the issuer, address, or credential is no longer usable' do
    with_atproto_client do |key|
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      world.bodies[:protected] = { 'authorization_servers' => ['https://moved.example'] }
      reset_atproto_exchanges!
      error = atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }
      expect(error.code).to eq('issuer_mismatch')
      expect(identity.reload.status).to eq('reauthentication_required')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)
      expect(exchanges_carrying(AtprotoOauthHelper::REFRESH_TOKEN)).to be_empty

      world.bodies[:protected] = { 'authorization_servers' => [atproto_issuer] }
      identity.update!(status: 'connected', last_error_code: nil, access_expires_at: 1.minute.ago)
      credential_for(identity).update!(expires_at: 1.minute.ago)
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)

      row = credential_for(identity)
      row.update!(expires_at: nil, revoked_at: Time.current)
      identity.reload.update!(status: 'connected', last_error_code: nil, refresh_started_at: nil, access_expires_at: 1.minute.ago)
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')

      credential_for(identity).update!(revoked_at: nil)
      identity.reload.update!(status: 'connected', last_error_code: nil, refresh_started_at: nil, access_expires_at: 1.minute.ago, token_endpoint: 'https://evil.example/oauth/token')
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('reauthentication_required')
      expect(atproto_exchanges.select { |exchange| exchange.uri.host == 'evil.example' }).to be_empty

      identity.reload.update!(token_endpoint: "#{atproto_issuer}/oauth/token", status: 'connected', last_error_code: nil, refresh_started_at: nil, access_expires_at: 1.minute.ago)
      ClimateControl.modify(ATPROTO_OAUTH_SIGNING_KEY: OpenSSL::PKey::EC.generate('prime256v1').to_pem, ATPROTO_OAUTH_SIGNING_KID: 'replacement') do
        reset_atproto_exchanges!
        expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('reauthentication_required')
        expect(atproto_exchanges.map(&:method)).not_to include(:post)
      end
      expect(key.private?).to be(true)
    end
  end

  it 'does not follow a redirect on the token endpoint' do
    with_atproto_client do
      world = install_atproto_world!
      world.bodies[:token_handler] = lambda do |_request|
        { status: 302, headers: { 'Location' => 'https://evil.example/oauth/token' }, body: '' }
      end
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: world.dns) }.code).to eq('redirect_rejected')
      expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('evil.example')
      expect(ExternalIdentity.count).to eq(0)
    end
  end

  it 'revokes locally even when the remote revocation fails, and does not revive the session' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      world.bodies[:revoke_response] = { status: 500, body: 'nope' }
      disconnected = ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
      expect(disconnected.status).to eq('disconnected')
      expect(disconnected.revocation_state).to eq('remote_failed')
      expect(credential_for(identity).reload.revoked_at).to be_present
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')

      attempt = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      identity.update!(disconnected_at: Time.current)
      expect(atproto_error { finish_atproto!(user: user, state: attempt[:state], dns: world.dns) }.code).to eq('stale_callback')
      expect(identity.reload.status).to eq('disconnected')
      expect(identity.credential.reload.revoked_at).to be_present
    end
  end

  it 'stops a callback that loses the race with disconnect' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      world.bodies[:token_handler] = lambda do |_request|
        travel 2.seconds
        ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
        atproto_json(atproto_tokens(refresh: 'refresh-during-disconnect'))
      end
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: world.dns) }.code).to eq('stale_callback')
      expect(identity.reload.status).to eq('disconnected')
      expect(UserExternalCredential.where(user_id: user.id, revoked_at: nil, credential_type: 'oauth_session')).to be_empty
    end
  end

  it 'refuses new OAuth and refresh when the flag or allowlist excludes the user' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      Setting.external_bridge_atproto = false
      reset_atproto_exchanges!
      expect(atproto_error { start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns) }.code).to eq('feature_disabled')
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('feature_disabled')
      expect(atproto_exchanges).to be_empty
      expect(identity.reload.status).to eq('connected')
      expect(credential_for(identity).revoked_at).to be_nil

      Setting.external_bridge_atproto = true
      Setting.external_bridge_atproto_testers = ''
      started = nil
      enable_atproto!(user)
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      Setting.external_bridge_atproto_testers = ''
      reset_atproto_exchanges!
      expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: world.dns) }.code).to eq('tester_only')
      expect(atproto_exchanges.map(&:method)).not_to include(:post)
      expect(ExternalServices::Bluesky.visible_to?(user)).to be(false)
      expect(ExternalServices::Registry.catalog_for(user).map(&:provider_key)).not_to include('bluesky')
    end
  end

  it 'deletes identities, attempts, and vault rows with the user and creates no status' do
    with_atproto_client do
      before_statuses = Status.count
      world = install_atproto_world!
      connected = connect_atproto!(user: user, world: world)
      start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      user_id = user.id
      credential_id = connected[:identity].credential_id
      user.destroy
      expect(ExternalIdentity.where(user_id: user_id)).to be_empty
      expect(ExternalOauthAttempt.where(user_id: user_id)).to be_empty
      expect(UserExternalCredential.where(id: credential_id)).to be_empty
      expect(Status.count).to eq(before_statuses)
    end
    source = Dir[Rails.root.join('app/services/external_bridge/atproto/*.rb')].map { |path| File.read(path) }.join
    expect(source).not_to include('createRecord')
    expect(source).not_to include('com.atproto.repo')
    expect(PostingIdentity::ENABLED_KINDS).to eq(['local'])
  end

  it 'keeps the shipped flag off and publishes client metadata without the private key' do
    text = File.read(Rails.root.join('config/settings.yml'))
    expect(text).to include('external_bridge_atproto: false')
    expect(text).to include("external_bridge_atproto_testers: ''")
    expect(ExternalBridge::Atproto::ClientDocument.metadata).to be_nil

    with_atproto_client do |key|
      document = ExternalBridge::Atproto::ClientDocument.metadata
      expect(document['token_endpoint_auth_method']).to eq('private_key_jwt')
      expect(document['dpop_bound_access_tokens']).to be(true)
      expect(document['grant_types']).to eq(%w(authorization_code refresh_token))
      expect(document['redirect_uris']).to eq([ExternalBridge::Atproto::ClientDocument.redirect_uri])
      jwks = ExternalBridge::Atproto::ClientDocument.jwks
      expect(jwks['keys'].first['kty']).to eq('EC')
      expect(jwks.to_json).not_to include(key.to_pem)
      expect(jwks['keys'].first).not_to have_key('d')
    end

    https = Rails.configuration.x.use_https
    host = Rails.configuration.x.web_domain
    Rails.configuration.x.use_https = false
    expect(ExternalBridge::Atproto::ClientDocument.metadata).to be_nil
    Rails.configuration.x.use_https = true
    Rails.configuration.x.web_domain = 'localhost'
    expect(ExternalBridge::Atproto::ClientDocument.origin).to be_nil
    Rails.configuration.x.web_domain = 'example.test:443'
    expect(ExternalBridge::Atproto::ClientDocument.origin).to be_nil
  ensure
    Rails.configuration.x.use_https = https
    Rails.configuration.x.web_domain = host
  end
end
