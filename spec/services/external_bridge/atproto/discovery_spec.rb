# frozen_string_literal: true

require 'rails_helper'

describe ExternalBridge::Atproto::Discovery do
  let(:user) { Fabricate(:user) }

  before { enable_atproto!(user) }

  def discovered(identifier, world)
    described_class.call(identifier, dns: world.dns)
  end

  it 'binds a handle to the DID document PDS and a separate entryway' do
    world = install_atproto_world!
    with_atproto_client do
      result = discovered(AtprotoOauthHelper::HANDLE, world)

      expect(result.input_kind).to eq('handle')
      expect(result.did).to eq(AtprotoOauthHelper::DID)
      expect(result.handle).to eq(AtprotoOauthHelper::HANDLE)
      expect(result.resource_origin).to eq(atproto_pds)
      expect(result.issuer).to eq(atproto_issuer)
      expect(result.token_endpoint).to eq("#{atproto_issuer}/oauth/token")
      expect(result.par_endpoint).to eq("#{atproto_issuer}/oauth/par")
    end
  end

  it 'resolves did:plc without using the handle host as the PDS' do
    world = install_atproto_world!
    with_atproto_client do
      result = discovered(AtprotoOauthHelper::DID, world)

      expect(result.input_kind).to eq('did')
      expect(result.did).to eq(AtprotoOauthHelper::DID)
      expect(result.resource_origin).to eq(atproto_pds)
      expect(result.issuer).to eq(atproto_issuer)
      expect(exchanges_carrying('Authorization')).to be_empty
    end
  end

  it 'resolves a self-hosted did:web from its well-known document' do
    document = atproto_document(did: AtprotoOauthHelper::WEB_DID, pds: 'https://self.example')
    world = install_atproto_world!(
      did: AtprotoOauthHelper::WEB_DID,
      pds: 'https://self.example',
      issuer: 'https://self.example',
      document: document,
    )
    with_atproto_client do
      result = discovered(AtprotoOauthHelper::WEB_DID, world)

      expect(result.did).to eq(AtprotoOauthHelper::WEB_DID)
      expect(result.resource_origin).to eq('https://self.example')
      expect(result.issuer).to eq('https://self.example')
      expect(atproto_exchanges.map { |exchange| exchange.uri.host }).to include('self.example')
      expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('plc.directory')
    end
  end

  it 'starts from a PDS hostname without binding a DID' do
    world = install_atproto_world!
    with_atproto_client do
      result = discovered('https://pds.example', world)

      expect(result.input_kind).to eq('hostname')
      expect(result.did).to be_nil
      expect(result.handle).to be_nil
      expect(result.resource_origin).to eq(atproto_pds)
      expect(result.issuer).to eq(atproto_issuer)
      expect(result.login_hint).to be_nil
    end
  end

  it 'rejects a handle whose DID document names a different alsoKnownAs value' do
    document = atproto_document(handle: 'other.example')
    world = install_atproto_world!(document: document)

    error = atproto_error { discovered(AtprotoOauthHelper::HANDLE, world) }

    expect(error.code).to eq('discovery_rejected')
    expect(atproto_exchanges.map(&:method)).not_to include(:post)
  end

  it 'rejects conflicting DNS TXT DIDs and does not fall through to HTTPS' do
    world = install_atproto_world!(txt: { "_atproto.#{AtprotoOauthHelper::HANDLE}" => ["did=#{AtprotoOauthHelper::DID}", "did=#{AtprotoOauthHelper::OTHER_DID}"] })

    error = atproto_error { discovered(AtprotoOauthHelper::HANDLE, world) }

    expect(error.code).to eq('discovery_rejected')
    expect(atproto_exchanges.select { |exchange| exchange.uri.path == '/.well-known/atproto-did' }).to be_empty
  end

  it 'rejects a PDS that resolves to a private address before opening a request' do
    world = install_atproto_world!(addresses: { AtprotoOauthHelper::PDS_HOST => ['127.0.0.1'] })

    error = atproto_error { discovered(AtprotoOauthHelper::DID, world) }

    expect(error.code).to eq('private_address')
    expect(atproto_exchanges.select { |exchange| exchange.uri.host == AtprotoOauthHelper::PDS_HOST }).to be_empty
  end

  it 'rejects a metadata redirect instead of following it' do
    world = install_atproto_world!(metadata_response: { status: 302, headers: { 'Location' => 'https://evil.example/oauth-authorization-server' }, body: '' })

    error = atproto_error { discovered(AtprotoOauthHelper::DID, world) }

    expect(error.code).to eq('redirect_rejected')
    expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('evil.example')
  end

  it 'rejects authorization-server metadata that is not JSON' do
    world = install_atproto_world!(metadata_response: { status: 200, headers: { 'Content-Type' => 'text/html' }, body: '<html></html>' })

    expect(atproto_error { discovered(AtprotoOauthHelper::DID, world) }.code).to eq('discovery_rejected')
  end

  it 'rejects authorization-server metadata that is not HTTP 200' do
    world = install_atproto_world!(metadata_response: { status: 201, headers: { 'Content-Type' => 'application/json' }, body: '{}' })

    expect(atproto_error { discovered(AtprotoOauthHelper::DID, world) }.code).to eq('discovery_rejected')
  end

  it 'rejects a protected resource that names more than one authorization server' do
    world = install_atproto_world!(protected_body: { 'authorization_servers' => [atproto_issuer, 'https://other.example'] })

    expect(atproto_error { discovered(AtprotoOauthHelper::DID, world) }.code).to eq('discovery_rejected')
  end

  it 'rejects a token endpoint that is not on the issuer origin' do
    metadata = atproto_metadata
    metadata['token_endpoint'] = 'https://evil.example/oauth/token'
    world = install_atproto_world!(metadata: metadata)

    expect(atproto_error { discovered(AtprotoOauthHelper::DID, world) }.code).to eq('issuer_mismatch')
    expect(atproto_exchanges.map(&:method)).not_to include(:post)
  end

  it 'rejects an authorization server whose issuer field is a different origin' do
    metadata = atproto_metadata
    metadata['issuer'] = 'https://evil.example'
    world = install_atproto_world!(metadata: metadata)

    expect(atproto_error { discovered(AtprotoOauthHelper::DID, world) }.code).to eq('issuer_mismatch')
  end

  it 'rejects an http PDS endpoint and an unsupported DID method' do
    http_document = atproto_document
    http_document['service'][0]['serviceEndpoint'] = 'http://pds.example'
    http_world = install_atproto_world!(document: http_document)
    expect(atproto_error { discovered(AtprotoOauthHelper::DID, http_world) }.code).to eq('discovery_rejected')
    expect(atproto_error { discovered('did:key:z6Mkexample', http_world) }.code).to eq('discovery_rejected')
  end

  it 'follows a handle well-known redirect only after the next address is public' do
    world = install_atproto_world!(
      txt: {},
      handle_http: { status: 302, headers: { 'Location' => 'https://10.0.0.8/atproto-did' }, body: '' },
    )

    error = atproto_error { discovered(AtprotoOauthHelper::HANDLE, world) }

    expect(error.code).to eq('private_address')
    expect(atproto_exchanges.map { |exchange| exchange.uri.host }).not_to include('10.0.0.8')
    expect(atproto_exchanges.map(&:method)).not_to include(:post)
  end
end
