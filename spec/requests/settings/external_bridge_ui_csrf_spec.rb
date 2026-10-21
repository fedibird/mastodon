# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External bridge settings CSRF' do
  let(:user) { Fabricate(:user, password: '123456789') }

  before { stub_webpacker_manifest }

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it 'does not subscribe from a POST without the CSRF token' do
    enable_external_bridge_rss!(user)
    sign_in user, scope: :user

    expect do
      post settings_external_services_rss_subscriptions_path, params: { feed_url: 'https://feeds.example/csrf.xml' }
    end.not_to change(ExternalSubscription, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'does not disconnect a Bluesky identity without the CSRF token' do
    identity = ExternalIdentity.create!(
      user: user,
      provider: 'bluesky',
      subject: 'did:plc:csrfexample0000000000',
      issuer: 'https://entry.example',
      resource_origin: 'https://pds.example',
      token_endpoint: 'https://entry.example/oauth/token',
      handle: 'alice.example',
      status: 'connected',
      terms_state: 'unreviewed',
      granted_scopes: ['atproto']
    )
    sign_in user, scope: :user

    delete settings_external_services_bluesky_identity_path(identity)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(identity.reload.disconnected_at).to be_nil
    expect(identity.status).to eq('connected')
  end
end
