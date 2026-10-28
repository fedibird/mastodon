# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

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
      post :create, params: { feed_url: feed_url }, session: challenge
    end.not_to change(ExternalSource, :count)

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(flash[:alert]).to eq I18n.t('external_bridge.errors.tester_only')
    expect(a_request(:get, feed_url)).not_to have_been_made
  end

  it 'subscribes an allowlisted tester from the HTML form' do
    sign_in tester, scope: :user

    expect do
      post :create, params: { feed_url: feed_url }, session: challenge
    end.to change(ExternalSubscription, :count).by(1)

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(ExternalSubscription.find_by(user_id: ordinary.id)).to be_nil
  end

  it 'translates an HTTP failure and does not repeat the address' do
    sign_in tester, scope: :user
    missing = 'https://feeds.example/missing.xml'
    stub_request(:get, missing).to_return(status: 404, body: 'missing')

    expect do
      post :create, params: { feed_url: missing }, session: challenge
    end.not_to change(ExternalSubscription, :count)

    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.http_status', status: '404'))
    expect(flash[:alert]).not_to include('http_404')
    expect(flash[:alert]).not_to include('missing.xml')
    expect(response.location).not_to include('missing.xml')
  end

  it 'does not subscribe without a recent challenge or echo a rejected URL' do
    sign_in tester, scope: :user
    secret_url = 'https://user:secret-token@feeds.example/private.xml'

    expect do
      post :create, params: { feed_url: secret_url }
    end.not_to change(ExternalSubscription, :count)

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(response.location).not_to include('secret-token')
    expect(flash[:alert].to_s).not_to include('secret-token')
    expect(session.to_s).not_to include('secret-token')

    post :create, params: { feed_url: secret_url }, session: challenge

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(response.location).not_to include('secret-token')
    expect(flash[:alert].to_s).not_to include('secret-token')
    expect(session.to_s).not_to include('secret-token')
    filtered = controller.request.filtered_parameters
    expect(filtered['feed_url']).to eq('[FILTERED]')
    expect(filtered.to_s).not_to include('secret-token')
  end

  it 'filters only the HTML feed parameter and leaves other url keys visible' do
    secret = 'https://user:secret-token@feeds.example/private.xml'
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      feed_url: secret,
      url: 'https://feeds.example/api.xml',
      canonical_url: 'https://feeds.example/public.xml',
      site_url: 'https://example.com/'
    )

    expect(filtered[:feed_url]).to eq('[FILTERED]')
    expect(filtered[:url]).to eq('https://feeds.example/api.xml')
    expect(filtered[:canonical_url]).to eq('https://feeds.example/public.xml')
    expect(filtered[:site_url]).to eq('https://example.com/')
    expect(filtered.to_s).not_to include('secret-token')
  end

  it 'redirects after accepting an unsubscribe even when the streaming push fails' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    list = Fabricate(:list, account: tester.account)
    enable_external_bridge_feeds!(tester)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: tester, subscription_id: owned[:subscription].id, home: true, list_ids: [list.id],
      expected_revision: owned[:subscription].feed_routes_revision
    )
    allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

    Sidekiq::Testing.fake! do
      delete :destroy, params: { id: owned[:subscription].id }, session: challenge
    end

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(response).to have_http_status(:see_other)
    expect(flash[:notice]).to eq I18n.t('external_bridge.unsubscribed')
    expect(owned[:subscription].reload.state).to eq 'deleting'
    deletion = ExternalSubscriptionDeletion.find_by!(external_subscription_id: owned[:subscription].id)
    expect(deletion.control_enqueued_at).to be_nil
    expect(deletion.route_targets).to include({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
  end

  it 'redirects when recording the streaming event fails in the database' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    enable_external_bridge_feeds!(tester)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: tester, subscription_id: owned[:subscription].id, home: true, list_ids: [],
      expected_revision: owned[:subscription].feed_routes_revision
    )
    allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_return('accepted-jid')
    allow_any_instance_of(ExternalSubscriptionDeletion).to receive(:update_columns).and_wrap_original do |method, attrs|
      raise ActiveRecord::StatementInvalid, 'SECRET_SQL_DETAIL' if attrs.key?(:control_enqueued_at)

      method.call(attrs)
    end

    Sidekiq::Testing.fake! do
      delete :destroy, params: { id: owned[:subscription].id }, session: challenge
    end

    expect(response).to have_http_status(:see_other)
    expect(flash[:notice]).to eq I18n.t('external_bridge.unsubscribed')
    expect(owned[:subscription].reload.state).to eq 'deleting'
    deletion = ExternalSubscriptionDeletion.find_by!(external_subscription_id: owned[:subscription].id)
    expect(deletion.control_enqueued_at).to be_nil
    expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
  end

  it 'pauses, resumes, and removes only the signed-in user subscription' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    other = share_account_user(tester.account)
    foreign = project_for(other)

    post :pause, params: { id: foreign[:subscription].id }, session: challenge
    expect(foreign[:subscription].reload.state).to eq('active')
    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.not_found'))

    post :pause, params: { id: owned[:subscription].id }, session: challenge
    expect(owned[:subscription].reload.state).to eq('paused')

    stub_request(:get, owned[:source].canonical_key).to_return(status: 200, body: rss_document(rss_item(guid: 'resumed')))
    post :resume, params: { id: owned[:subscription].id }, session: challenge
    expect(owned[:subscription].reload.state).to eq('active')

    source_id = owned[:source].id
    delete :destroy, params: { id: foreign[:subscription].id }, session: challenge
    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.not_found'))
    expect(foreign[:subscription].reload.state).to eq('active')

    delete :destroy, params: { id: owned[:subscription].id }, session: challenge
    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(response).to have_http_status(:see_other)
    expect(flash[:notice]).to eq(I18n.t('external_bridge.unsubscribed'))
    delete :destroy, params: { id: owned[:subscription].id }, session: challenge
    expect(flash[:alert]).to be_nil

    expect(ExternalSubscription.where(id: owned[:subscription].id)).to be_empty
    expect(ExternalSubscriptionDeletion.where(external_subscription_id: owned[:subscription].id).count).to eq 1
    expect(ExternalSource.where(id: source_id)).to exist
    expect(foreign[:subscription].reload).to be_present
  end

  it 'saves display choices for a paused feed without rewriting posts in the request' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    owned[:subscription].update!(state: 'paused')
    other = share_account_user(tester.account)
    foreign = project_for(other)
    allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '1', cw_enabled: '0' }, session: challenge

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(response).to have_http_status(:see_other)
    expect(flash[:notice]).to eq(I18n.t('external_bridge.presentation.saved_applying'))
    expect(owned[:subscription].reload.media_sensitive).to eq(true)
    expect(owned[:subscription].cw_enabled).to eq(false)
    expect(owned[:subscription].presentation_revision).to eq(1)
    expect(owned[:subscription].presentation_applied_revision).to eq(0)
    expect(owned[:status].reload.sensitive).to eq(false)
    expect(foreign[:subscription].reload.media_sensitive).to eq(false)
    expect(ExternalBridge::RSS::PresentationReconcileWorker).to have_received(:perform_async).with(owned[:subscription].id, 1, 0, kind_of(String))
  end

  it 'does not save display choices for another user or a feed that is being removed' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    other = share_account_user(tester.account)
    foreign = project_for(other)
    owned[:subscription].update!(state: 'deleting')

    patch :update, params: { id: foreign[:subscription].id, media_sensitive: '1', cw_enabled: '1' }, session: challenge
    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.not_found'))
    expect(foreign[:subscription].reload.cw_enabled).to eq(false)

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '1', cw_enabled: '1' }, session: challenge
    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.subscription_deleting'))
    expect(owned[:subscription].reload.media_sensitive).to eq(false)
  end

  it 'saves a fixed language, automatic detection, and an explicit unspecified value' do
    sign_in tester, scope: :user
    owned = project_for(tester)
    other = share_account_user(tester.account)
    foreign = project_for(other)
    allow(ExternalBridge::RSS::PresentationReconcileWorker).to receive(:perform_async).and_return('jid')

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '0', cw_enabled: '0', language: 'ja' }, session: challenge
    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(owned[:subscription].reload.language_mode).to eq('fixed')
    expect(owned[:subscription].language).to eq('ja')
    expect(foreign[:subscription].reload.language_mode).to eq('unspecified')

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '0', cw_enabled: '0', language: 'auto' }, session: challenge
    expect(owned[:subscription].reload.language_mode).to eq('auto')
    expect(owned[:subscription].language).to be_nil

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '0', cw_enabled: '0', language: 'unspecified' }, session: challenge
    expect(owned[:subscription].reload.language_mode).to eq('unspecified')
    expect(owned[:subscription].language).to be_nil
    expect(owned[:subscription].presentation_revision).to eq(3)
    expect(owned[:source].reload.attributes).not_to have_key('language_mode')
  end

  it 'rejects an unknown language without changing the feed' do
    sign_in tester, scope: :user
    owned = project_for(tester)

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '1', cw_enabled: '1', language: 'zz' }, session: challenge

    expect(flash[:alert]).to eq(I18n.t('external_bridge.errors.invalid_presentation'))
    expect(owned[:subscription].reload.language_mode).to eq('unspecified')
    expect(owned[:subscription].media_sensitive).to eq(false)
    expect(owned[:subscription].presentation_revision).to eq(0)
  end

  it 'requires a recent challenge before saving display choices' do
    sign_in tester, scope: :user
    owned = project_for(tester)

    patch :update, params: { id: owned[:subscription].id, media_sensitive: '1', cw_enabled: '1' }

    expect(response).to redirect_to(settings_external_services_rss_path)
    expect(owned[:subscription].reload.media_sensitive).to eq(false)
    expect(owned[:subscription].presentation_revision).to eq(0)
  end
end

# rubocop:enable Metrics/BlockLength
