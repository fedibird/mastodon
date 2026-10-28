# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe Settings::ExternalServices::RSSController do
  render_views

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
    enable_external_bridge_rss!(user)
  end

  def deletion_for(owner)
    world = project_for(owner, body: 'Hidden imported body')
    world[:source].update!(title: 'Deleting <b>feed</b>')
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: owner, subscription_id: world[:subscription].id)
  end

  it 'shows a progress card with a status region and no actions for the deleting subscription' do
    deletion = deletion_for(user)
    deletion.update_columns(state: 'running', total_count: 200, deleted_count: 50)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    card = document.at_css("#rss-deletion-#{deletion.id}")
    expect(card['data-state']).to eq 'running'
    expect(card['data-poll-url']).to eq settings_external_services_rss_subscription_deletion_path(deletion.id)
    status = card.at_css("[role='status']")
    expect(status['aria-live']).to eq 'polite'
    expect(status.text).to include(I18n.t('external_bridge.deletion.message.running'))
    progress = card.at_css('progress')
    expect(progress['value']).to eq '25'
    expect(progress['max']).to eq '100'
    expect(card.text).to include('150')
    expect(response.body).to include('Deleting &lt;b&gt;feed&lt;/b&gt;')
    expect(response.body).not_to include('Deleting <b>feed</b>')
    expect(card.at_css('form[hidden]')).to be_present
    dismiss = card.at_css("form[action='#{settings_dismiss_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(dismiss['hidden']).to be_present
    close = dismiss.at_css("input[type='submit']")
    expect(close['value']).to eq I18n.t('external_bridge.deletion.dismiss')
    expect(close['aria-label']).to eq I18n.t('external_bridge.deletion.dismiss_for', title: 'Deleting <b>feed</b>')
    expect(card['data-status-url']).to eq settings_external_services_rss_subscription_deletion_path(deletion.id)
    expect(card['data-hide-after-ms']).to be_nil

    subscription_card = document.at_css("[data-deleting-subscription-id='#{deletion.external_subscription_id}']")
    expect(subscription_card).to be_present
    expect(subscription_card.text).to include(I18n.t('external_bridge.state.deleting'))
    expect(subscription_card.text).to include(I18n.t('external_bridge.deletion.subscription_note'))
    expect(subscription_card.at_css('form')).to be_nil
    expect(subscription_card.at_css('button')).to be_nil
    expect(response.body).not_to include('Hidden imported body')
  end

  it 'shows the retry on a failed job and stops polling for a finished one' do
    deletion = deletion_for(user)
    deletion.update_columns(state: 'failed', last_error_code: 'database_error', total_count: 10, deleted_count: 4, next_run_at: nil)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    card = document.at_css("#rss-deletion-#{deletion.id}")
    expect(card['data-poll-url']).to be_nil
    expect(card.text).to include(I18n.t('external_bridge.deletion.message.failed'))
    expect(card.text).to include(I18n.t('external_bridge.deletion.errors.database_error'))
    form = card.at_css("form[action='#{settings_retry_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(form).to be_present
    expect(form['hidden']).to be_nil
    dismiss = card.at_css("form[action='#{settings_dismiss_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(dismiss['hidden']).to be_present
    expect(card['data-hide-after-ms']).to be_nil

    ExternalSubscriptionDeletion.where(id: deletion.id).update_all(state: 'completed', finished_at: Time.current)
    get :show, session: challenge
    card = Nokogiri::HTML(response.body).at_css("#rss-deletion-#{deletion.id}")
    expect(card.text).to include(I18n.t('external_bridge.deletion.message.completed'))
    expect(card['data-poll-url']).to be_nil
    expect(card['data-status-url']).to eq settings_external_services_rss_subscription_deletion_path(deletion.id)
    expect(card['data-hide-after-ms'].to_i).to be_within(10_000).of(24.hours.in_milliseconds)
    dismiss = card.at_css("form[action='#{settings_dismiss_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(dismiss['hidden']).to be_nil
    close = dismiss.at_css("input[type='submit']")
    expect(close['value']).to eq I18n.t('external_bridge.deletion.dismiss')
    expect(close['aria-label']).to eq I18n.t('external_bridge.deletion.dismiss_for', title: 'Deleting <b>feed</b>')
    expect(card.at_css("form[action='#{settings_retry_external_services_rss_subscription_deletion_path(deletion.id)}']")['hidden']).to be_present
  end

  it 'keeps polling a failed card that will be retried by itself and hides its retry button' do
    deletion = deletion_for(user)
    deletion.update_columns(state: 'failed', last_error_code: 'database_error', attempt_count: 1, next_run_at: 2.minutes.from_now, total_count: 10, deleted_count: 4)

    get :show, session: challenge

    card = Nokogiri::HTML(response.body).at_css("#rss-deletion-#{deletion.id}")
    expect(card['data-poll-url']).to eq settings_external_services_rss_subscription_deletion_path(deletion.id)
    expect(card.text).to include(I18n.t('external_bridge.deletion.message.retrying'))
    expect(card.text).to include(I18n.t('external_bridge.deletion.state.retrying'))
    form = card.at_css("form[action='#{settings_retry_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(form['hidden']).to be_present
  end

  it 'renders Japanese copy and keeps another user out' do
    user.update!(locale: 'ja')
    deletion_for(user)
    other = share_account_user(user.account)
    theirs = deletion_for(other)

    get :show, session: challenge

    expect(response.body).to include('購読削除の進捗と履歴')
    expect(response.body).to include('削除を受け付けました。まもなく開始します。')
    expect(response.body).to include('対象の件数を確認しています（準備中）。')
    expect(response.body).to include('閉じる')
    expect(response.body).to include('の完了した進捗を閉じる')
    expect(response.body).not_to include("rss-deletion-#{theirs.id}")
  end

  def persist_deletion(owner, attributes = {})
    @deletion_seq = (@deletion_seq || 9_600_000_000) + 1
    ExternalSubscriptionDeletion.create!(
      {
        user: owner,
        external_subscription_id: @deletion_seq,
        external_source_id: @deletion_seq,
        state: 'completed',
        requested_at: Time.current,
        finished_at: Time.current,
        route_targets: [],
      }.merge(attributes)
    )
  end

  it 'shows a completion from the last 24 hours and hides one that has reached the boundary' do
    now = Time.zone.parse('2026-10-28 12:00:00')
    shown = nil
    boundary = nil
    older = nil
    dismissed = nil
    failed = nil

    travel_to(now) do
      shown = persist_deletion(user, finished_at: now - 23.hours - 59.minutes)
      boundary = persist_deletion(user, finished_at: now - 24.hours)
      older = persist_deletion(user, finished_at: now - 25.hours)
      dismissed = persist_deletion(user, finished_at: now - 1.hour, dismissed_at: now)
      failed = persist_deletion(user, state: 'failed', finished_at: now - 10.days, next_run_at: nil, last_error_code: 'database_error')

      get :show, session: challenge
    end

    expect(response.body).to include(%(id="rss-deletion-#{shown.id}"))
    expect(response.body).to include(%(id="rss-deletion-#{failed.id}"))
    [boundary, older, dismissed].each do |hidden|
      expect(response.body).not_to include(%(id="rss-deletion-#{hidden.id}"))
      expect(ExternalSubscriptionDeletion.exists?(hidden.id)).to be true
    end
  end

  it 'fills the ten cards from visible rows, after newer dismissed and expired rows' do
    visible = Array.new(12) { persist_deletion(user, finished_at: 1.hour.ago) }
    dismissed = Array.new(3) { persist_deletion(user, finished_at: 30.minutes.ago, dismissed_at: Time.current) }
    expired = Array.new(3) { persist_deletion(user, finished_at: 26.hours.ago) }
    sqls = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      sqls << sql if sql.include?('external_subscription_deletions') && sql.include?('SELECT')
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      get :show, session: challenge
    end

    ids = Nokogiri::HTML(response.body).css('[data-deletion-progress]').map { |node| node['id'] }
    expect(ids).to eq(visible.last(10).reverse.map { |row| "rss-deletion-#{row.id}" })
    (dismissed + expired + visible.first(2)).each do |hidden|
      expect(ids).not_to include("rss-deletion-#{hidden.id}")
      expect(ExternalSubscriptionDeletion.exists?(hidden.id)).to be true
    end
    expect(sqls.size).to eq 1
    expect(sqls.first).to match(/ORDER BY "external_subscription_deletions"\."id" DESC LIMIT /)
    expect(sqls.first.index('LIMIT')).to be > sqls.first.index('dismissed_at')
    expect(sqls.first).to include('dismissed_at')
  end

  it 'does not list a deleting feed among the imported items' do
    deletion_for(user)

    get :show, session: challenge

    expect(response.body).not_to include('Imported title')
    expect(response.body).to include(I18n.t('external_bridge.no_items'))
  end
end

# rubocop:enable Metrics/BlockLength
