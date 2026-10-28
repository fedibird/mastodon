# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe 'RSS subscription language' do
  let(:owner) { Fabricate(:user, locale: 'ja') }
  let(:english_article) { 'Hello and welcome to the paper lighthouse how are you today?' }
  let(:japanese_article) { '灯台の番人は青い紙の舟を数えて、嵐が来る前に手帳へ名前を書いた。海は静かに見えても、波はまだ遠くまで続いていた。' }

  before do
    enable_external_bridge_rss!(owner)
    owner.settings['default_language'] = 'ja'
  end

  around do |example|
    previous = I18n.default_locale
    I18n.default_locale = :ja
    I18n.with_locale(:ja) { example.run }
  ensure
    I18n.default_locale = previous
  end

  def feed_for(user, body:, title: 'Imported title')
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml",
      title: 'Public feed',
      site_url: 'https://example.com',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{source.canonical_key}\nitem:guid-1",
      title: title,
      body: body,
      canonical_url: 'https://example.com/posts/1',
      byline: 'Ada',
      revision: 'rev-1',
      published_at: Time.utc(2020, 1, 2, 3, 4, 5)
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    { source: source, resource: resource, subscription: subscription }
  end

  def project!(world)
    status, marker = ExternalBridge::ProjectionWriter.new.create!(
      user: world[:subscription].user,
      subscription: world[:subscription],
      resource: world[:resource]
    )
    world.merge(status: status, marker: marker)
  end

  def save!(subscription, **attrs)
    ExternalBridge::RSS::PresentationUpdate.new.call(
      user: subscription.user,
      subscription_id: subscription.id,
      **attrs
    )
  end

  it 'stores unspecified for a new subscription and does not put that choice on the shared feed' do
    world = feed_for(owner, body: english_article)

    expect(world[:subscription].language_mode).to eq('unspecified')
    expect(world[:subscription].language).to be_nil
    expect(ExternalSource.column_names).not_to include('language_mode')
    expect(ExternalResource.column_names).not_to include('language_mode')
    migration = Rails.root.join('db/migrate/20261108120000_add_language_choice_to_external_subscriptions.rb').read
    expect(migration).to include("default: 'unspecified'")
    expect(migration).not_to match(/UPDATE\s+statuses/i)
    expect(migration).not_to include('update_all')
  end

  it 'keeps a new unspecified projection unset and does not call detection' do
    world = feed_for(owner, body: english_article)

    expect(LanguageDetector.instance).not_to receive(:detect)
    world = project!(world)

    expect(world[:status].language).to be_nil
  end

  it 'uses one decision for a fixed language, automatic detection, and unspecified' do
    fixed = project!(feed_for(owner, body: english_article))
    save!(fixed[:subscription], language_mode: 'fixed', language: 'ja')
    expect(fixed[:status].reload.language).to eq('ja')

    automatic = project!(feed_for(owner, body: english_article))
    save!(automatic[:subscription], language_mode: 'auto')
    expect(automatic[:status].reload.language).to eq('en')

    unset = project!(feed_for(owner, body: japanese_article))
    save!(unset[:subscription], language_mode: 'unspecified')
    expect(unset[:status].reload.language).to be_nil
  end

  it 'does not fall back to the interface language for a short, empty, or unclear article' do
    short = project!(feed_for(owner, body: '', title: 'Hi'))
    empty = project!(feed_for(owner, body: '', title: ''))
    url_only = project!(feed_for(owner, body: 'https://example.com/items/1', title: ''))
    html = feed_for(
      owner,
      title: '<b>灯台だより</b>',
      body: '<p>番人が青い紙の舟を数えて、嵐の前に手帳へ名前を書いた。</p><a href="https://example.com/items/1">https://example.com/items/1</a>'
    )

    calls = []
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |method, text, account, **kwargs|
      calls << [text, account, kwargs]
      method.call(text, account, **kwargs)
    end

    save!(short[:subscription], language_mode: 'auto')
    save!(empty[:subscription], language_mode: 'auto')
    save!(url_only[:subscription], language_mode: 'auto')
    save!(html[:subscription], language_mode: 'auto')
    html_status, = ExternalBridge::ProjectionWriter.new.create!(
      user: owner,
      subscription: html[:subscription].reload,
      resource: html[:resource]
    )

    expect(short[:status].reload.language).to be_nil
    expect(empty[:status].reload.language).to be_nil
    expect(url_only[:status].reload.language).to be_nil
    expect(html_status.language).to eq('ja')
    expect(calls).not_to be_empty
    expect(calls).to all(include(nil, { allow_fallback: false }))
    joined = calls.map(&:first).join("\n")
    expect(joined).not_to include(I18n.t('external_bridge.untitled_article'))
    expect(joined).not_to include('Ada')
  end

  it 'detects from the title and body and ignores the warning and the generated excerpt' do
    resource = ExternalResource.new(
      title: '灯台だより',
      body: japanese_article,
      byline: 'Ada',
      canonical_url: 'https://example.com/posts/1'
    )
    calls = []
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |method, text, account, **kwargs|
      calls << [text, account, kwargs]
      method.call(text, account, **kwargs)
    end

    hidden = ExternalBridge::RSS::Presentation.for(resource, media_sensitive: true, cw_enabled: true, language_mode: 'auto')
    shown = ExternalBridge::RSS::Presentation.for(resource, media_sensitive: false, cw_enabled: false, language_mode: 'auto')

    expect(hidden.language).to eq('ja')
    expect(shown.language).to eq(hidden.language)
    expect(hidden.spoiler_text).to eq('灯台だより')
    expect(calls.map(&:first).uniq).to eq(["灯台だより\n\n#{japanese_article}"])
    expect(calls.first.first).not_to include('https://example.com/posts/1')
    expect(calls.first.first).not_to include(hidden.text)
  end

  it 'keeps a fixed or unspecified language when the article changes and redetects only automatic mode' do
    fixed = project!(feed_for(owner, body: english_article))
    save!(fixed[:subscription], language_mode: 'fixed', language: 'ja')
    fixed[:resource].update!(title: '新しい題', body: japanese_article, revision: 'rev-2')
    ExternalBridge::RSS::Materialize.new.call(subscription: fixed[:subscription].reload, resources: [fixed[:resource].reload])
    expect(fixed[:status].reload.language).to eq('ja')
    expect(fixed[:status].text).to include('新しい題')

    automatic = project!(feed_for(owner, body: english_article))
    save!(automatic[:subscription], language_mode: 'auto')
    expect(automatic[:status].reload.language).to eq('en')
    status_id = automatic[:status].id
    automatic[:resource].update!(title: '新しい題', body: japanese_article, revision: 'rev-2')
    ExternalBridge::RSS::Materialize.new.call(subscription: automatic[:subscription].reload, resources: [automatic[:resource].reload])
    expect(automatic[:status].reload.language).to eq('ja')
    expect(automatic[:status].id).to eq(status_id)

    unset = project!(feed_for(owner, body: english_article))
    unset[:resource].update!(body: japanese_article, revision: 'rev-2')
    expect(LanguageDetector.instance).not_to receive(:detect)
    ExternalBridge::RSS::Materialize.new.call(subscription: unset[:subscription].reload, resources: [unset[:resource].reload])
    expect(unset[:status].reload.language).to be_nil
  end

  it 'does not change language when only the warning or sensitive flag changes' do
    world = project!(feed_for(owner, body: english_article))
    save!(world[:subscription], language_mode: 'fixed', language: 'en')
    created_at = world[:status].reload.created_at

    expect(LanguageDetector.instance).not_to receive(:detect)
    save!(world[:subscription].reload, media_sensitive: true, cw_enabled: true)

    status = world[:status].reload
    expect(status.language).to eq('en')
    expect(status.sensitive).to eq(true)
    expect(status.spoiler_text).to eq('Imported title')
    expect(status.created_at).to eq(created_at)

    save!(world[:subscription].reload, media_sensitive: false, cw_enabled: false)
    expect(world[:status].reload.language).to eq('en')
    expect(world[:status].spoiler_text).to eq('')
  end

  it 'rewrites the same status and leaves another user on the same account alone' do
    world = project!(feed_for(owner, body: english_article))
    roommate = share_account_user(owner.account)
    enable_external_bridge_rss!(roommate)
    roommate_subscription = ExternalSubscription.create!(user: roommate, external_source: world[:source], state: 'active')
    roommate_status, = ExternalBridge::ProjectionWriter.new.create!(
      user: roommate,
      subscription: roommate_subscription,
      resource: world[:resource]
    )
    stranger = Fabricate(:user)
    enable_external_bridge_rss!(stranger)
    stranger_world = project!(feed_for(stranger, body: english_article))
    favourite = Fabricate(:favourite, account: owner.account, status: world[:status])
    bookmark = Fabricate(:bookmark, account: owner.account, status: world[:status])
    status_id = world[:status].id
    distributed = []
    allow(DistributionWorker).to receive(:perform_async) { |*args| distributed << args }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |*args| distributed << args }

    save!(world[:subscription], language_mode: 'fixed', language: 'ja')

    status = world[:status].reload
    expect(status.id).to eq(status_id)
    expect(status.language).to eq('ja')
    expect(favourite.reload.status_id).to eq(status_id)
    expect(bookmark.reload.status_id).to eq(status_id)
    expect(roommate_status.reload.language).to be_nil
    expect(roommate_subscription.reload.language_mode).to eq('unspecified')
    expect(roommate_status.account_id).to eq(status.account_id)
    expect(stranger_world[:status].reload.language).to be_nil
    expect(stranger_world[:subscription].reload.language_mode).to eq('unspecified')
    expect(world[:source].reload.attributes).not_to have_key('language_mode')
    expect(world[:resource].reload.attributes).not_to have_key('language')
    expect(distributed).to eq([])
  end

  it 'lets the latest language win and ignores a stale generation' do
    world = project!(feed_for(owner, body: english_article))
    save!(world[:subscription], language_mode: 'fixed', language: 'ja')
    expect(world[:status].reload.language).to eq('ja')

    Sidekiq::Testing.fake! do
      save!(world[:subscription].reload, language_mode: 'fixed', language: 'en')
    end
    expect(world[:subscription].reload.presentation_revision).to eq(2)
    expect(world[:status].reload.language).to eq('ja')

    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(
      world[:subscription].id, 1, 0, 'stale-token'
    )
    expect(world[:status].reload.language).to eq('ja')

    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(
      world[:subscription].id,
      2,
      0,
      world[:subscription].reload.presentation_lease_token
    )
    expect(world[:status].reload.language).to eq('en')
    expect(world[:subscription].reload.presentation_applied_revision).to eq(2)
  end

  it 'applies the saved language during import and does not let an older job replace it' do
    world = project!(feed_for(owner, body: english_article))
    first_token = nil
    Sidekiq::Testing.fake! do
      save!(world[:subscription], language_mode: 'fixed', language: 'ja')
      first_token = world[:subscription].reload.presentation_lease_token
      save!(world[:subscription].reload, language_mode: 'fixed', language: 'en')
    end
    status_id = world[:status].id
    world[:resource].update!(body: "#{english_article} The keeper added another line today.", revision: 'rev-2')

    ExternalBridge::RSS::Materialize.new.call(subscription: world[:subscription].reload, resources: [world[:resource].reload])
    expect(world[:status].reload.language).to eq('en')

    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(world[:subscription].id, 1, 0, first_token)
    expect(world[:status].reload.id).to eq(status_id)
    expect(world[:status].language).to eq('en')
  end

  it 'reads the current language from the row rather than a stale subscription object' do
    world = project!(feed_for(owner, body: english_article))
    stale = ExternalSubscription.find(world[:subscription].id)
    world[:subscription].update_columns(language_mode: 'fixed', language: 'ja', presentation_revision: 4, presentation_applied_revision: 4)

    ExternalBridge::RSS::Materialize.new.call(subscription: stale, resources: [world[:resource]])

    expect(world[:status].reload.language).to eq('ja')
    expect(stale.language_mode).to eq('unspecified')
  end

  it 'does not apply language to a subscription that is being removed' do
    world = project!(feed_for(owner, body: english_article))
    world[:subscription].update_columns(
      state: 'deleting',
      language_mode: 'fixed',
      language: 'ja',
      presentation_revision: 3,
      presentation_applied_revision: 0,
      presentation_lease_token: 'doomed-token',
      presentation_lease_until: 10.minutes.from_now
    )

    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(world[:subscription].id, 3, 0, 'doomed-token')

    expect(world[:status].reload.language).to be_nil
    expect { save!(world[:subscription].reload, language_mode: 'fixed', language: 'en') }.to raise_error(ExternalBridge::Error) { |error|
      expect(error.code).to eq('subscription_deleting')
    }
    expect(world[:status].reload.language).to be_nil
    expect(world[:subscription].reload.language).to eq('ja')
  end

  it 'rejects a fixed language with no supported code at the database' do
    world = feed_for(owner, body: english_article)

    expect do
      ExternalSubscription.transaction(requires_new: true) do
        world[:subscription].update_columns(language_mode: 'fixed', language: nil)
      end
    end.to raise_error(ActiveRecord::StatementInvalid)

    expect(world[:subscription].reload.language_mode).to eq('unspecified')
  end
end

# rubocop:enable Metrics/BlockLength
