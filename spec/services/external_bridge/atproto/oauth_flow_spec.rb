# frozen_string_literal: true

require 'rails_helper'

describe 'AT Protocol OAuth identity connection' do
  let(:user) { Fabricate(:user) }

  before { enable_atproto!(user) }

  def credential_for(identity)
    UserExternalCredential.find(identity.credential_id)
  end

  def assertion_kid(exchange)
    fields = Rack::Utils.parse_nested_query(exchange.body.to_s)
    decode_jwt(fields.fetch('client_assertion'))[:header]['kid']
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
      expect(fields['scope']).to eq('atproto')
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
    expect(identity.granted_scopes).to eq(['atproto'])
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
      escalated.bodies[:token] = atproto_tokens(scope: 'atproto transition:email')
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

  it 'stores an atproto grant and rejects a callback with the wrong browser, issuer, or code' do
    with_atproto_client do
      partial = install_atproto_world!
      partial.bodies[:token] = atproto_tokens(scope: 'atproto')
      identity = connect_atproto!(user: user, world: partial).fetch(:identity)
      expect(identity.status).to eq('connected')
      expect(identity.last_error_code).to be_nil
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

  it 'requests only atproto when the server advertises a repo subset, and retries PAR with a new DPoP nonce' do
    with_atproto_client do
      calls = []
      allowed = install_atproto_world!(metadata: atproto_metadata(scopes: %w(atproto repo:app.bsky.feed.like transition:generic)))
      allowed.bodies[:par_handler] = lambda do |request|
        calls << request.headers['Dpop']
        if calls.size == 1
          { status: 400, headers: { 'Content-Type' => 'application/json', 'DPoP-Nonce' => 'nonce-from-server' }, body: '{"error":"use_dpop_nonce"}' }
        else
          atproto_json({ 'request_uri' => 'urn:ietf:params:oauth:request_uri:two' })
        end
      end
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: allowed.dns)
      fields = Rack::Utils.parse_nested_query(atproto_exchanges.reverse.find { |exchange| exchange.uri.path == '/oauth/par' }.body)
      expect(fields['scope']).to eq('atproto')
      expect(fields['scope']).not_to include('transition:generic')
      expect(fields['scope']).not_to include('repo:')
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
        expect(refreshed.subject).to eq(AtprotoOauthHelper::DID)
        expect(refreshed.refresh_started_at).to be_nil
        expect(revealed(refreshed)['refresh_token']).to eq('refresh-after-SENTINEL')
      end
      posts = exchanges_carrying('refresh-before-SENTINEL')
      expect(posts.map { |exchange| [exchange.uri.host, exchange.uri.path] }).to eq([[AtprotoOauthHelper::ISSUER_HOST, '/oauth/token']])
      expect(exchanges_carrying('refresh-before-SENTINEL', 'refresh-after-SENTINEL').map { |exchange| exchange.uri.host }.uniq).to eq([AtprotoOauthHelper::ISSUER_HOST])
    end
  end

  it 'does not replace the vault when refresh returns another subject, no subject, or an invalid DID' do
    with_atproto_client do
      world = install_atproto_world!
      [
        atproto_tokens(did: AtprotoOauthHelper::OTHER_DID, refresh: 'refresh-other-subject'),
        atproto_tokens(refresh: 'refresh-missing-subject').except('sub'),
        atproto_tokens(did: 'not-a-did', refresh: 'refresh-invalid-subject'),
        atproto_tokens(refresh: 'refresh-other-issuer').merge('iss' => 'https://evil.example'),
      ].each do |token_body|
        world.bodies[:token] = atproto_tokens
        identity = connect_atproto!(user: user, world: world).fetch(:identity)
        ciphertext = credential_for(identity).encrypted_payload
        world.bodies[:token] = token_body
        reset_atproto_exchanges!
        travel 5.minutes do
          expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq(token_body['iss'] ? 'issuer_mismatch' : 'authorization_rejected')
        end
        row = credential_for(identity).reload
        expect(row.encrypted_payload).to eq(ciphertext)
        expect(row.revoked_at).to be_present
        expect(identity.reload.subject).to eq(AtprotoOauthHelper::DID)
        expect(identity.refresh_generation).to eq(0)
        expect(identity.refresh_started_at).to be_present
        expect(atproto_exchanges.map { |exchange| exchange.uri.to_s }).not_to include(a_string_including('com.atproto.repo'))
        expect(atproto_exchanges.map { |exchange| exchange.body.to_s }.join).not_to include('createRecord')
        expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('evil.example')
        reset_atproto_exchanges!
        expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('reauthentication_required')
        expect(atproto_exchanges.map(&:method)).not_to include(:post)
      end
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

  it 'keeps a connected session through a metadata outage and refreshes after discovery recovers' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      ciphertext = credential_for(identity).encrypted_payload
      travel 5.minutes do
        [503, :timeout].each do |failure|
          if failure == 503
            world.bodies[:metadata_status] = 503
            world.bodies[:metadata_handler] = nil
          else
            world.bodies[:metadata_status] = 200
            world.bodies[:metadata_handler] = -> { raise HTTP::TimeoutError, 'metadata timed out' }
          end
          reset_atproto_exchanges!
          expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('discovery_rejected')
          row = identity.reload
          expect(row.status).to eq('connected')
          expect(row.last_error_code).to eq('discovery_rejected')
          expect(row.refresh_started_at).to be_nil
          expect(row.refresh_generation).to eq(0)
          expect(credential_for(identity).reload.encrypted_payload).to eq(ciphertext)
          expect(credential_for(identity).revoked_at).to be_nil
          expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
        end

        world.bodies[:metadata_handler] = nil
        world.bodies[:metadata_status] = 200
        world.bodies[:token] = atproto_tokens(expires_in: 300, refresh: 'refresh-after-outage')
        reset_atproto_exchanges!
        refreshed = ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns)
        expect(refreshed.status).to eq('connected')
        expect(refreshed.refresh_generation).to eq(1)
        expect(refreshed.last_error_code).to be_nil
        expect(revealed(refreshed)['refresh_token']).to eq('refresh-after-outage')
        expect(atproto_exchanges.select { |exchange| exchange.method == :post && exchange.uri.path == '/oauth/token' }.size).to eq(1)
      end
    end
  end

  it 'requires sign-in again when the bound issuer changes and does not send the refresh token later' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      ciphertext = credential_for(identity).encrypted_payload
      world.bodies[:protected] = { 'authorization_servers' => ['https://moved.example'] }
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('issuer_mismatch')
      expect(identity.reload.status).to eq('reauthentication_required')
      expect(identity.last_error_code).to eq('issuer_mismatch')
      expect(credential_for(identity).encrypted_payload).to eq(ciphertext)
      expect(credential_for(identity).revoked_at).to be_nil
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty

      world.bodies[:protected] = { 'authorization_servers' => [atproto_issuer] }
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('reauthentication_required')
      expect(identity.reload.status).to eq('reauthentication_required')
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
    end
  end

  it 'signs the callback and refresh with the PAR key after the current key changes' do
    old_key = OpenSSL::PKey::EC.generate('prime256v1')
    current_key = OpenSSL::PKey::EC.generate('prime256v1')
    previous = "par-kid:#{Base64.strict_encode64(old_key.to_pem)}"
    with_atproto_client do
      world = install_atproto_world!
      started = nil
      ClimateControl.modify(ATPROTO_OAUTH_SIGNING_KEY: old_key.to_pem, ATPROTO_OAUTH_SIGNING_KID: 'par-kid') do
        started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      end
      par = atproto_exchanges.reverse.find { |exchange| exchange.uri.path == '/oauth/par' }
      expect(assertion_kid(par)).to eq('par-kid')
      expect(ExternalOauthAttempt.order(:id).last.client_key_id).to eq('par-kid')

      ClimateControl.modify(
        ATPROTO_OAUTH_SIGNING_KEY: current_key.to_pem,
        ATPROTO_OAUTH_SIGNING_KID: 'current-kid',
        ATPROTO_OAUTH_PREVIOUS_SIGNING_KEYS: previous,
      ) do
        reset_atproto_exchanges!
        identity = finish_atproto!(user: user, state: started[:state], dns: world.dns)
        token_post = atproto_exchanges.find { |exchange| exchange.method == :post && exchange.uri.path == '/oauth/token' }
        expect(assertion_kid(token_post)).to eq('par-kid')
        expect(revealed(identity)['client_key_id']).to eq('par-kid')

        world.bodies[:token] = atproto_tokens(refresh: 'refresh-with-par-kid')
        reset_atproto_exchanges!
        travel 5.minutes do
          refreshed = ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns)
          expect(refreshed.refresh_generation).to eq(1)
          expect(revealed(refreshed)['client_key_id']).to eq('par-kid')
        end
        refresh_post = atproto_exchanges.find { |exchange| exchange.method == :post && exchange.uri.path == '/oauth/token' }
        expect(assertion_kid(refresh_post)).to eq('par-kid')

        identity.reload.update!(status: 'connected', last_error_code: nil, refresh_started_at: nil, access_expires_at: 1.minute.ago)
      end

      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: ExternalIdentity.last.id, dns: world.dns) }.code).to eq('reauthentication_required')
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
    end
  end

  it 'does not exchange an authorization code with a signing key that was not used at PAR' do
    old_key = OpenSSL::PKey::EC.generate('prime256v1')
    with_atproto_client do
      world = install_atproto_world!
      started = nil
      ClimateControl.modify(ATPROTO_OAUTH_SIGNING_KEY: old_key.to_pem, ATPROTO_OAUTH_SIGNING_KID: 'par-kid') do
        started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns)
      end
      ClimateControl.modify(ATPROTO_OAUTH_SIGNING_KEY: OpenSSL::PKey::EC.generate('prime256v1').to_pem, ATPROTO_OAUTH_SIGNING_KID: 'current-kid') do
        reset_atproto_exchanges!
        expect(atproto_error { finish_atproto!(user: user, state: started[:state], dns: world.dns) }.code).to eq('signing_key_unavailable')
      end
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
      expect(ExternalIdentity.count).to eq(0)
      expect(ExternalOauthAttempt.order(:id).last.consumed_at).to be_nil
      expect(ExternalOauthAttempt.order(:id).last.client_key_id).to eq('par-kid')
    end
  end

  it 'disconnects locally when the stored session cannot be revoked remotely' do
    with_atproto_client do
      world = install_atproto_world!
      credential = store_vault_credential(
        owner: user,
        provider: 'bluesky',
        purpose: 'identity',
        credential_type: 'oauth_session',
        credentials: { 'access_token' => 'incomplete-session-without-refresh' },
      )
      identity = ExternalIdentity.create!(
        user: user,
        provider: 'bluesky',
        subject: AtprotoOauthHelper::DID,
        issuer: atproto_issuer,
        resource_origin: atproto_pds,
        token_endpoint: "#{atproto_issuer}/oauth/token",
        revocation_endpoint: "#{atproto_issuer}/oauth/revoke",
        status: 'connected',
        terms_state: 'approved',
        granted_scopes: ['atproto'],
        credential: credential,
        access_expires_at: 1.minute.ago,
      )
      reset_atproto_exchanges!
      disconnected = ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
      expect(disconnected.status).to eq('disconnected')
      expect(disconnected.disconnected_at).to be_present
      expect(disconnected.revocation_state).to eq('remote_failed')
      expect(credential.reload.revoked_at).to be_present
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
    end
  end

  it 'revokes the rotated refresh token when disconnect wins during refresh' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      ciphertext = credential_for(identity).encrypted_payload
      rotated = 'refresh-rotated-SENTINEL-not-stored'
      world.bodies[:token_handler] = lambda do |request|
        fields = Rack::Utils.parse_nested_query(request.body.to_s)
        next atproto_json(atproto_tokens) unless fields['grant_type'] == 'refresh_token'

        ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
        atproto_json(atproto_tokens(refresh: rotated))
      end
      reset_atproto_exchanges!
      travel 5.minutes do
        expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
      end
      row = identity.reload
      expect(row.status).to eq('disconnected')
      expect(row.disconnected_at).to be_present
      expect(row.refresh_generation).to eq(0)
      expect(row.revocation_state).to eq('successor_revoked')
      expect(credential_for(identity).reload.revoked_at).to be_present
      expect(credential_for(identity).encrypted_payload).to eq(ciphertext)
      revoke_posts = atproto_exchanges.select { |exchange| exchange.method == :post && exchange.uri.path == '/oauth/revoke' }
      expect(revoke_posts.map { |exchange| exchange.body.to_s }.join).to include(rotated)
      expect(revoke_posts.map { |exchange| [exchange.uri.host, exchange.uri.path] }.uniq).to eq([[AtprotoOauthHelper::ISSUER_HOST, '/oauth/revoke']])
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }.map { |exchange| exchange.uri.host }.uniq).to eq([AtprotoOauthHelper::ISSUER_HOST])
      expect_secret_absent!(rotated)
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
    end
  end

  it 'keeps the session disconnected when revocation of the rotated refresh token fails' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      ciphertext = credential_for(identity).encrypted_payload
      rotated = 'refresh-rotated-failed-SENTINEL'
      world.bodies[:revoke_handler] = lambda do |request|
        fields = Rack::Utils.parse_nested_query(request.body.to_s)
        next atproto_json({}) unless fields['token'] == rotated

        { status: 500, body: 'nope' }
      end
      world.bodies[:token_handler] = lambda do |request|
        fields = Rack::Utils.parse_nested_query(request.body.to_s)
        next atproto_json(atproto_tokens) unless fields['grant_type'] == 'refresh_token'

        ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: world.dns)
        atproto_json(atproto_tokens(refresh: rotated))
      end
      reset_atproto_exchanges!
      travel 5.minutes do
        expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('revoked')
      end
      expect(identity.reload.status).to eq('disconnected')
      expect(identity.revocation_state).to eq('successor_revoke_failed')
      expect(credential_for(identity).reload.encrypted_payload).to eq(ciphertext)
      expect(credential_for(identity).revoked_at).to be_present
      expect(atproto_exchanges.select { |exchange| exchange.method == :post && exchange.uri.path == '/oauth/revoke' }.map { |exchange| exchange.body.to_s }.join).to include(rotated)
      expect_secret_absent!(rotated)
    end
  end

  it 'requires sign-in again when authorization-server metadata drops atproto' do
    with_atproto_client do
      world = install_atproto_world!
      identity = connect_atproto!(user: user, world: world).fetch(:identity)
      world.bodies[:metadata] = atproto_metadata(scopes: %w(transition:generic))
      reset_atproto_exchanges!
      expect(atproto_error { ExternalBridge::Atproto::Refresh.call(user: user, identity_id: identity.id, dns: world.dns) }.code).to eq('unsupported_scopes')
      expect(identity.reload.status).to eq('reauthentication_required')
      expect(identity.last_error_code).to eq('unsupported_scopes')
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
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
