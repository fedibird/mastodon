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
    deletion.update_columns(state: 'failed', last_error_code: 'database_error', total_count: 10, deleted_count: 4)

    get :show, session: challenge

    document = Nokogiri::HTML(response.body)
    card = document.at_css("#rss-deletion-#{deletion.id}")
    expect(card['data-poll-url']).to be_nil
    expect(card.text).to include(I18n.t('external_bridge.deletion.message.failed'))
    expect(card.text).to include(I18n.t('external_bridge.deletion.errors.database_error'))
    form = card.at_css("form[action='#{settings_retry_external_services_rss_subscription_deletion_path(deletion.id)}']")
    expect(form).to be_present
    expect(form['hidden']).to be_nil

    ExternalSubscriptionDeletion.where(id: deletion.id).update_all(state: 'completed', finished_at: Time.current)
    get :show, session: challenge
    card = Nokogiri::HTML(response.body).at_css("#rss-deletion-#{deletion.id}")
    expect(card.text).to include(I18n.t('external_bridge.deletion.message.completed'))
    expect(card['data-poll-url']).to be_nil
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
    expect(response.body).not_to include("rss-deletion-#{theirs.id}")
  end

  it 'does not list a deleting feed among the imported items' do
    deletion_for(user)

    get :show, session: challenge

    expect(response.body).not_to include('Imported title')
    expect(response.body).to include(I18n.t('external_bridge.no_items'))
  end
end

# rubocop:enable Metrics/BlockLength
