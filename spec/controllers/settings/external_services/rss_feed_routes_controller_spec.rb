# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::RSSFeedRoutesController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }
  let(:bundle) { external_project_for(user, body: 'Settings article') }
  let(:subscription) { bundle[:subscription] }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
  end

  it 'asks for the recent challenge before writing' do
    enable_external_bridge_feeds!(user)

    expect do
      patch :update, params: { id: subscription.id, feed_route: { home: '1', list_ids: [''], expected_revision: '0' } }
    end.not_to change(ExternalFeedRoute, :count)

    expect(response).to redirect_to(settings_external_services_rss_path)
  end

  it 'saves home and an owned list for the signed-in user' do
    enable_external_bridge_feeds!(user)
    list = Fabricate(:list, account: user.account, title: 'Morning')

    patch :update, params: {
      id: subscription.id,
      user_id: Fabricate(:user).id,
      feed_route: { home: '1', list_ids: ['', list.id.to_s], expected_revision: '0' },
    }, session: challenge

    expect(response).to have_http_status(:see_other)
    expect(flash[:notice]).to eq I18n.t('external_bridge.feed_routes.saved')
    expect(ExternalFeedRoute.where(user_id: user.id).pluck(:destination, :list_id)).to contain_exactly(['home', nil], ['list', list.id])
    expect(subscription.reload.feed_routes_revision).to eq 1
  end

  it 'offers only the saved destinations when delivery is off' do
    enable_external_bridge_feeds!(user)
    kept = Fabricate(:list, account: user.account, title: 'Kept list')
    other = Fabricate(:list, account: user.account, title: 'Unselected list')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: subscription.id, home: true, list_ids: [kept.id], expected_revision: 0)
    Setting.external_bridge_feeds = false

    patch :update, params: {
      id: subscription.id,
      feed_route: { home: '0', list_ids: [''], expected_revision: '1' },
    }, session: challenge

    expect(response).to have_http_status(:see_other)
    expect(ExternalFeedRoute.where(external_subscription_id: subscription.id)).to be_empty
    expect(Status.exists?(bundle[:status].id)).to be true
    expect(other.account_id).to eq user.account_id
  end

  it 're-renders the current revision when the submitted one is stale' do
    enable_external_bridge_feeds!(user)
    subscription.update_columns(feed_routes_revision: 2)

    patch :update, params: {
      id: subscription.id,
      feed_route: { home: '1', list_ids: [''], expected_revision: '0' },
    }, session: challenge

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include(I18n.t('external_bridge.feed_routes.stale'))
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("input[name='feed_route[expected_revision]']")['value']).to eq '2'
    expect(ExternalFeedRoute.where(external_subscription_id: subscription.id)).to be_empty
  end

  it 'does not save another user subscription, even one on the same account' do
    enable_external_bridge_feeds!(user)
    roommate = share_account_user(user.account)
    other = external_project_for(roommate, body: 'Hidden roommate feed')

    patch :update, params: {
      id: other[:subscription].id,
      user_id: user.id,
      feed_route: { home: '1', list_ids: [''], expected_revision: '0' },
    }, session: challenge

    expect(response).to have_http_status(:see_other)
    expect(flash[:alert]).to eq I18n.t('external_bridge.feed_routes.errors.not_found')
    expect(flash[:alert]).not_to include('Hidden roommate feed')
    expect(ExternalFeedRoute.where(user_id: roommate.id)).to be_empty
  end
end
