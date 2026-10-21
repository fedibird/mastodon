# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::RSSController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  it 'asks for the password challenge before showing feeds' do
    get :show

    expect(response).to have_http_status(200)
    expect(response.body).to include('form_challenge')
    expect(response.body).not_to include('id="rss-feed-url"')
  end

  it 'shows the feed form only to a permitted tester and keeps the value empty' do
    enable_external_bridge_rss!(user)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    field = document.at_css('#rss-feed-url')
    expect(field['type']).to eq('url')
    expect(field['name']).to eq('feed_url')
    expect(field['value']).to be_blank
    expect(response.body).to include(I18n.t('external_bridge.feed_url_hint'))
    expect(response.body).to include(I18n.t('external_bridge.privacy_note'))
    expect(response.body).not_to include('type="password"')
  end

  it 'hides the form when the flag is off and still shows an owned feed' do
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/owned.xml', title: 'Owned feed')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active', checked_at: Time.zone.parse('2026-10-20 12:00:00 UTC'))
    Setting.external_bridge_rss = false

    get :show, session: challenge

    expect(response.body).to include(I18n.t('external_bridge.disabled'))
    expect(response.body).to include(I18n.t('external_bridge.privacy_note'))
    expect(response.body).to include('Owned feed')
    expect(response.body).not_to include('id="rss-feed-url"')
    expect(response.body).to include(settings_pause_external_services_rss_subscription_path(ExternalSubscription.last.id))
  end

  it 'escapes feed titles and asks before a destructive unsubscribe' do
    enable_external_bridge_rss!(user)
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: 'https://feeds.example/long.xml',
      title: '<img src=x onerror=alert(1)>'
    )
    subscription = ExternalSubscription.create!(
      user: user,
      external_source: source,
      state: 'error',
      last_error_code: 'fetch_failed',
      failed_item_count: 2,
      retry_count: 3,
      next_retry_at: Time.zone.parse('2026-10-21 01:00:00 UTC'),
      checked_at: Time.zone.parse('2026-10-20 12:00:00 UTC')
    )

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')
    expect(response.body).not_to include('<img src=x onerror=alert(1)>')
    expect(response.body).to include(I18n.t('external_bridge.state.error'))
    expect(response.body).to include(I18n.t('external_bridge.errors.fetch_failed'))
    expect(response.body).to include(I18n.t('external_bridge.partial_item_failure', count: 2))
    expect(response.body).to include(I18n.t('external_bridge.retry_status', time: I18n.l(subscription.next_retry_at), count: 3))
    button = document.at_css("form[action='#{settings_external_services_rss_subscription_path(subscription)}'] input[type='submit']")
    expect(button['data-confirm']).to eq(I18n.t('external_bridge.unsubscribe_confirm'))
    expect(button['data-disable-with']).to eq(I18n.t('external_bridge.working'))
    expect(document.at_css("form[action='#{settings_resume_external_services_rss_subscription_path(subscription)}']")).to be_present
  end

  it 'does not show another user on the same account' do
    other = share_account_user(user.account)
    projected = project_for(other, body: 'Secret article body')
    projected[:resource].update!(title: 'Hidden imported title')
    enable_external_bridge_rss!(user)

    get :show, session: challenge

    expect(response.body).not_to include('Hidden imported title')
    expect(response.body).not_to include('Secret article body')
    expect(response.body).not_to include(projected[:source].canonical_key)
    expect(response.body).to include(I18n.t('external_bridge.no_subscriptions'))
  end

  it 'renders the Japanese empty and paused states' do
    user.update!(locale: 'ja')
    enable_external_bridge_rss!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/ja.xml', title: '日本語フィード')
    ExternalSubscription.create!(user: user, external_source: source, state: 'error', last_error_code: 'malformed_feed')

    get :show, session: challenge

    expect(response.body).to include('フィードURL')
    expect(response.body).to include('取得エラー')
    expect(response.body).to include('公開のRSSまたはAtomではありませんでした。')
    expect(response.body).to include('この購読から取り込んだ自分専用の投稿')
  end
end
