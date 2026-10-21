# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::BlueskyController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  it 'asks for the password challenge before showing the connection page' do
    get :show

    expect(response).to have_http_status(200)
    expect(response.body).to include('form_challenge')
    expect(response.body).not_to include('name="account"')
  end

  it 'shows the DID and hides the connect form and tokens while the flag is off' do
    with_atproto_client do
      enable_atproto!(user)
      world = connect_atproto!(user: user).fetch(:world)
      use_atproto_dns!(world)
      Setting.external_bridge_atproto = false

      get :show, session: challenge
    end

    expect(response.body).to include(I18n.t('external_bridge.atproto.disabled'))
    expect(response.body).to include(AtprotoOauthHelper::DID)
    expect(response.body).to include(AtprotoOauthHelper::HANDLE)
    expect(response.body).to include(atproto_issuer)
    expect(response.body).not_to include('name="account"')
    expect(response.body).not_to include(AtprotoOauthHelper::REFRESH_TOKEN)
    expect(response.body).not_to include(AtprotoOauthHelper::ACCESS_TOKEN)
    expect(response.body).not_to include('PRIVATE KEY')
    expect(response.body).to include(settings_external_services_bluesky_identity_path(ExternalIdentity.find_by(user_id: user.id)))
  end

  it 'shows handle sign-in, advanced entry, and no token field when OAuth can start' do
    with_atproto_client do
      enable_atproto!(user)

      get :show, session: challenge
    end

    document = Nokogiri::HTML(response.body)
    field = document.at_css('#bluesky-handle')
    expect(field['type']).to eq('text')
    expect(field['placeholder']).to eq('alice.bsky.social')
    expect(field['value']).to be_blank
    expect(document.css('input[type="password"]')).to be_empty
    expect(response.body).to include(I18n.t('external_bridge.atproto.advanced'))
    expect(response.body).to include(I18n.t('external_bridge.atproto.scope_note'))
    expect(response.body).to include(I18n.t('external_bridge.atproto.live_gate_note'))
    expect(response.body).to include(I18n.t('external_bridge.atproto.return_note'))
    expect(response.body).not_to include('app_password')
    expect(response.body).not_to include('name="refresh_token"')
  end

  it 'uses sign-in again for a saved account and keeps disconnect behind a confirmation' do
    identity = nil
    with_atproto_client do
      enable_atproto!(user)
      identity = connect_atproto!(user: user).fetch(:identity)
      identity.update!(status: 'reauthentication_required', last_error_code: 'reauthentication_required', handle: 'renamed.example')

      get :show, session: challenge
    end

    document = Nokogiri::HTML(response.body)
    hidden = document.at_css("#bluesky-account-#{identity.id}")
    expect(hidden['value']).to eq(identity.subject)
    expect(hidden['value']).not_to eq('renamed.example')
    expect(hidden['value']).not_to eq(AtprotoOauthHelper::HANDLE)
    expect(document.css("form[action='#{settings_external_services_bluesky_authorize_path}'] button").map(&:text).join).to include(I18n.t('external_bridge.atproto.sign_in_again'))
    disconnect = document.at_css("form[action='#{settings_external_services_bluesky_identity_path(identity)}'] input[type='submit']")
    expect(disconnect['data-confirm']).to eq(I18n.t('external_bridge.atproto.disconnect_confirm'))
    expect(disconnect['data-disable-with']).to eq(I18n.t('external_bridge.working'))
    expect(response.body).to include(identity.issuer)
    expect(response.body).not_to include(identity.token_endpoint)
    expect(response.body).not_to include(AtprotoOauthHelper::REFRESH_TOKEN)
    expect(response.body).not_to include('PRIVATE KEY')
  end

  it 'offers reconnect and does not offer disconnect after the account is disconnected' do
    identity = nil
    with_atproto_client do
      enable_atproto!(user)
      identity = connect_atproto!(user: user).fetch(:identity)
      identity.update!(status: 'disconnected', disconnected_at: Time.zone.parse('2026-10-20 12:00:00 UTC'), revocation_state: 'remote_failed', handle: 'renamed.example')

      get :show, session: challenge
    end

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("#bluesky-account-#{identity.id}")['value']).to eq(identity.subject)
    expect(document.at_css("#bluesky-account-#{identity.id}")['value']).not_to eq('renamed.example')
    expect(document.css("form[action='#{settings_external_services_bluesky_identity_path(identity)}']")).to be_empty
    expect(response.body).to include(I18n.t('external_bridge.atproto.reconnect'))
    expect(response.body).to include(I18n.t('external_bridge.atproto.revocation.remote_failed'))
    expect(response.body).not_to include(identity.token_endpoint)
  end

  it 'disables a new sign-in when the signing key is missing and still allows disconnect' do
    identity = nil
    with_atproto_client do
      enable_atproto!(user)
      identity = connect_atproto!(user: user).fetch(:identity)
    end

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    expect(response.body).to include(I18n.t('external_bridge.atproto.errors.signing_key_unavailable'))
    expect(document.css('input[name="account"]')).to be_empty
    expect(document.at_css('button[disabled]')).to be_present
    expect(document.at_css("form[action='#{settings_external_services_bluesky_identity_path(identity)}']")).to be_present
  end
end

describe Settings::ExternalServices::BlueskyAuthorizationsController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789', locale: 'ja') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  it 'does not start OAuth without a recent challenge' do
    with_atproto_client do
      enable_atproto!(user)
      install_atproto_world!

      expect do
        post :create, params: { account: AtprotoOauthHelper::HANDLE }
      end.not_to change(ExternalOauthAttempt, :count)
    end

    expect(response).to redirect_to(settings_external_services_bluesky_path)
    expect(atproto_exchanges.map(&:method)).not_to include(:post)
  end

  it 'shows a Japanese safe error when discovery rejects the account' do
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!(addresses: { AtprotoOauthHelper::PDS_HOST => ['127.0.0.1'] })
      use_atproto_dns!(world)

      post :create, params: { account: AtprotoOauthHelper::DID }, session: challenge
    end

    expect(flash[:alert]).to eq('そのホストは公開サーバーではありません。')
    expect(flash[:alert]).not_to include('127.0.0.1')
    expect(response.location).not_to include(AtprotoOauthHelper::DID)
  end
end

describe Settings::ExternalServices::BlueskyCallbacksController do
  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc, atproto_oauth_browser: AtprotoOauthHelper::BROWSER } }

  before { sign_in user, scope: :user }

  it 'redirects without the authorization code or state' do
    with_atproto_client do
      enable_atproto!(user)
      world = install_atproto_world!
      use_atproto_dns!(world)
      started = start_atproto!(user: user, identifier: AtprotoOauthHelper::HANDLE, dns: world.dns, browser: AtprotoOauthHelper::BROWSER)

      get :show, params: { state: started[:state], iss: atproto_issuer, code: 'auth-code-1', error_description: 'leak-SENTINEL' }, session: challenge
    end

    expect(response).to redirect_to(settings_external_services_bluesky_path)
    expect(response.location).not_to include('auth-code-1')
    expect(response.location).not_to include('state=')
    expect(response.location).not_to include('leak-SENTINEL')
    expect(ExternalIdentity.where(user_id: user.id).count).to eq(1)
  end
end

describe Settings::ExternalServices::BlueskyIdentitiesController do
  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before { sign_in user, scope: :user }

  it 'does not let another user of the same account disconnect the identity' do
    other = share_account_user(user.account)
    identity = nil
    with_atproto_client do
      enable_atproto!(user, other)
      connected = connect_atproto!(user: user)
      use_atproto_dns!(connected.fetch(:world))
      identity = connected.fetch(:identity)
      sign_in other, scope: :user

      delete :destroy, params: { id: identity.id }, session: challenge
    end

    expect(flash[:alert]).to eq(I18n.t('external_bridge.atproto.errors.not_found'))
    expect(identity.reload.disconnected_at).to be_nil
  end

  it 'keeps the recorded revocation when disconnect is submitted twice' do
    identity = nil
    with_atproto_client do
      enable_atproto!(user)
      connected = connect_atproto!(user: user)
      use_atproto_dns!(connected.fetch(:world))
      identity = connected.fetch(:identity)
      ExternalBridge::Atproto::Disconnect.call(user: user, identity_id: identity.id, dns: connected.fetch(:world).dns)
    end

    %w(successor_revoked successor_revoke_failed).each do |state|
      identity.reload.update!(revocation_state: state, disconnected_at: Time.zone.parse('2026-10-20 12:00:00 UTC'))
      stamp = identity.reload.disconnected_at
      revoked_at = identity.credential.reload.revoked_at
      reset_atproto_exchanges!

      delete :destroy, params: { id: identity.id }, session: challenge
      delete :destroy, params: { id: identity.id }, session: challenge

      expect(response).to redirect_to(settings_external_services_bluesky_path)
      row = identity.reload
      expect(row.revocation_state).to eq(state)
      expect(row.disconnected_at).to eq(stamp)
      expect(row.status).to eq('disconnected')
      expect(row.credential.reload.revoked_at).to eq(revoked_at)
      expect(atproto_exchanges.select { |exchange| exchange.method == :post }).to be_empty
    end
  end
end
