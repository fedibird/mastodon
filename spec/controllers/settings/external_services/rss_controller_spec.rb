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
    expect(response.body).to include('RSS 1.0、RSS 2.0、Atomのいずれのフィードとしても読めませんでした。')
    expect(response.body).to include('この購読から取り込んだ自分専用の投稿')
  end

  it 'shows an HTTP status without the raw error code' do
    enable_external_bridge_rss!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/down.xml', title: 'Down')
    ExternalSubscription.create!(user: user, external_source: source, state: 'error', last_error_code: 'http_503')

    get :show, session: challenge

    expect(response.body).to include(I18n.t('external_bridge.errors.http_status', status: '503'))
    expect(response.body).not_to include('http_503')
  end

  it 'shows destination choices to a delivery tester and escapes the list title' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/routes.xml', title: 'Routed feed')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    Fabricate(:list, account: user.account, title: '<img src=x onerror=alert(1)>')

    get :show, session: challenge

    expect(response.body).to include(I18n.t('external_bridge.feed_routes.heading'))
    expect(response.body).to include(I18n.t('external_bridge.feed_routes.description'))
    expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')
    expect(response.body).not_to include('<img src=x onerror=alert(1)>')
    document = Nokogiri::HTML(response.body)
    form = document.at_css('form.feed-route-picker__form')
    expect(form).to be_present
    expect(form.at_css("input[name='feed_route[expected_revision]']")).to be_present
    expect(document.at_css("form[action='#{settings_pause_external_services_rss_subscription_path(ExternalSubscription.last)}']")).to be_present
  end

  it 'hides destination choices when delivery is off and nothing is saved' do
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/no-route.xml', title: 'No route feed')
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')

    get :show, session: challenge

    expect(response.body).not_to include(I18n.t('external_bridge.feed_routes.heading'))
    expect(response.body).to include(settings_pause_external_services_rss_subscription_path(subscription))
  end

  it 'shows only saved destinations when delivery is off' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/saved-route.xml', title: 'Saved route feed')
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    kept = Fabricate(:list, account: user.account, title: 'Kept list')
    Fabricate(:list, account: user.account, title: 'Unselected list')
    ExternalFeedRoute.create!(user: user, external_subscription: subscription, destination: 'home')
    ExternalFeedRoute.create!(user: user, external_subscription: subscription, destination: 'list', list_id: kept.id)
    Setting.external_bridge_feeds = false

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    form = document.at_css('form.feed-route-picker__form')
    expect(form.text).to include(I18n.t('external_bridge.feed_routes.disabled'))
    expect(form.text).to include('Kept list')
    expect(form.text).not_to include('Unselected list')
    expect(document.at_css('.feed-route-picker__summary').text).to include('Kept list')
    expect(document.at_css('[data-feed-route-create]')).to be_nil
  end

  it 'renders Japanese destination copy' do
    user.update!(locale: 'ja')
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/ja-routes.xml', title: '日本語フィード')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')

    get :show, session: challenge

    expect(response.body).to include('指定したタイムラインで新着投稿を受け取ります')
    expect(response.body).to include('受信先: 未指定')
    expect(response.body).to include('配信先を設定')
    expect(response.body).to include('+ 新しいリストを作成')
  end

  it 'summarizes saved destinations on a short line and keeps the long notes out' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/summary.xml', title: 'Summary feed')
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    lists = %w(Alpha Beta Gamma Delta).map { |title| Fabricate(:list, account: user.account, title: title) }
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: subscription.id, home: true, list_ids: lists.first(3).map(&:id), expected_revision: 0)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    expect(document.at_css('.feed-route-picker__summary').text).to eq 'Receives in: Home, Alpha and 2 more'
    expect(document.at_css('details.feed-route-picker__fallback summary').text.strip).to eq I18n.t('external_bridge.feed_routes.change')
    expect(document.css('form.feed-route-picker__form input[type=checkbox][checked]').map { |box| box['name'] }).to eq ['feed_route[home]', 'feed_route[list_ids][]', 'feed_route[list_ids][]', 'feed_route[list_ids][]']
    expect(document.css('form.feed-route-picker__form input[type=checkbox]').size).to eq 5
    expect(document.css('.feed-route-picker__description').map(&:text)).to eq [I18n.t('external_bridge.feed_routes.description')]
    expect(response.body).not_to include('keep_note')
    expect(document.at_css("[data-feed-route-create][hidden][data-url='#{settings_external_services_feed_route_lists_path}']")).to be_present
  end

  it 'offers the picker with home and list creation when the user has no lists' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/empty-lists.xml', title: 'Empty lists feed')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    expect(document.css('form.feed-route-picker__form input[type=checkbox]').map { |box| box['name'] }).to eq ['feed_route[home]']
    expect(document.at_css('[data-feed-route-create]')).to be_present
    expect(document.at_css('.feed-route-picker__summary').text).to eq 'Receives in: not set'
  end

  it 'keeps the unsubscribe confirmation on the card' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/unsub.xml', title: 'Unsub feed')
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    button = document.at_css("form[action='#{settings_external_services_rss_subscription_path(subscription)}'] .negative")
    expect(button['data-confirm']).to eq I18n.t('external_bridge.unsubscribe_confirm')
  end

  it 'does not offer list creation once the list limit is reached' do
    enable_external_bridge_feeds!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/limit.xml', title: 'Limit feed')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    rows = Array.new(List::PER_ACCOUNT_LIMIT) { |index| { account_id: user.account_id, title: "List #{index}", created_at: Time.current, updated_at: Time.current } }
    List.insert_all!(rows)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    expect(document.at_css('[data-feed-route-create]')).to be_nil
    expect(document.at_css('form.feed-route-picker__form').text).to include(I18n.t('lists.errors.limit'))
  end

  it 'loads routes and lists once for the subscriptions on the page' do
    enable_external_bridge_feeds!(user)
    Fabricate(:list, account: user.account, title: 'Only list')
    3.times do |index|
      source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/page#{index}.xml", title: "Feed #{index}")
      ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    end

    queries = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      get :show, session: challenge
    end

    expect(queries.count { |sql| sql.match?(/select/i) && sql.include?('external_feed_routes') }).to eq 1
    expect(queries.count { |sql| sql.match?(/select/i) && sql.include?('"lists"') }).to be <= 2
  end
end
