# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::RSSSubscriptionsController do
  let(:ordinary) { Fabricate(:user, password: '123456789') }
  let(:tester) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }
  let(:feed_url) { 'https://feeds.example/settings.xml' }

  before do
    sign_in ordinary, scope: :user
    Setting.external_bridge_rss = true
    permit_external_bridge_rss_testers!(tester)
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'settings')))
  end

  it 'does not subscribe an ordinary user from the HTML form' do
    expect do
      post :create, params: { url: feed_url }, session: challenge
    end.not_to change(ExternalSource, :count)

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(flash[:alert]).to eq I18n.t('external_bridge.errors.tester_only')
    expect(a_request(:get, feed_url)).not_to have_been_made
  end

  it 'subscribes an allowlisted tester from the HTML form' do
    sign_in tester, scope: :user

    expect do
      post :create, params: { url: feed_url }, session: challenge
    end.to change(ExternalSubscription, :count).by(1)

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(ExternalSubscription.find_by(user_id: ordinary.id)).to be_nil
  end
end
