# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe ExternalBridge::RSS::InitialLanguage do
  let(:japanese_article) { '灯台の番人は青い紙の舟を数えて、嵐が来る前に手帳へ名前を書いた。海は静かに見えても、波はまだ遠くまで続いていた。' }
  let(:english_article) { 'Hello and welcome to the paper lighthouse how are you today?' }

  def source_with(*articles)
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml",
      title: 'Paper lighthouse',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    articles.each_with_index do |article, index|
      ExternalResource.create!(
        external_source: source,
        protocol: 'rss',
        canonical_key: "item-#{index}-#{SecureRandom.hex(2)}",
        title: article.fetch(:title, ''),
        body: article.fetch(:body, ''),
        canonical_url: "https://example.com/posts/#{index}",
        published_at: article.fetch(:published_at, Time.current - index.minutes)
      )
    end
    source
  end

  it 'fixes one confident language, including a single useful article, and ignores empty text' do
    only_japanese = source_with({ title: '灯台だより', body: japanese_article })
    with_gaps = source_with(
      { title: '灯台だより', body: japanese_article },
      { title: '', body: '' },
      { title: '', body: 'https://example.com/items/1' },
      { title: '', body: '<p>https://example.com/items/2</p>' }
    )

    expect(described_class.attributes_for(only_japanese)).to eq(language_mode: 'fixed', language: 'ja')
    expect(described_class.attributes_for(with_gaps)).to eq(language_mode: 'fixed', language: 'ja')
    expect(described_class.attributes_for(source_with({ title: 'Lighthouse notes', body: english_article }))).to eq(language_mode: 'fixed', language: 'en')
  end

  it 'chooses automatic when more than one supported language is reliable' do
    mixed = source_with(
      { title: '灯台だより', body: japanese_article },
      { title: '灯台だより', body: japanese_article },
      { title: '灯台だより', body: japanese_article },
      { title: 'Lighthouse notes', body: english_article }
    )
    calls = []
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |method, text, account, **kwargs|
      calls << [text, account, kwargs]
      method.call(text, account, **kwargs)
    end

    expect(described_class.attributes_for(mixed)).to eq(language_mode: 'auto', language: nil)
    expect(calls.size).to eq(4)
    expect(calls).to all(include(nil, { allow_fallback: false }))
    expect(calls.map(&:first).any? { |text| text.include?(japanese_article) && text.include?(english_article) }).to be(false)
  end

  it 'stays unset when the sample is empty, too short, only a URL, unknown, unsupported, or mixed with text that cannot be judged' do
    empty = source_with
    short = source_with({ title: 'Hi', body: '' })
    url_only = source_with({ title: '', body: 'https://example.com/items/1' })
    unknown = source_with({ title: 'Note', body: 'This unresolved note has several plain words today.' })
    unsupported = source_with({ title: 'Note', body: 'This madeup note has several plain words today.' })
    confident_and_unknown = source_with(
      { title: '灯台だより', body: japanese_article },
      { title: 'Note', body: 'This unresolved note has several plain words today.' }
    )
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |method, text, account, **kwargs|
      next if text.include?('unresolved')
      next :zz if text.include?('madeup')

      method.call(text, account, **kwargs)
    end

    expect(described_class.attributes_for(empty)).to eq(language_mode: 'unspecified', language: nil)
    expect(described_class.attributes_for(short)).to eq(language_mode: 'unspecified', language: nil)
    expect(described_class.attributes_for(url_only)).to eq(language_mode: 'unspecified', language: nil)
    expect(described_class.attributes_for(unknown)).to eq(language_mode: 'unspecified', language: nil)
    expect(described_class.attributes_for(unsupported)).to eq(language_mode: 'unspecified', language: nil)
    expect(described_class.attributes_for(confident_and_unknown)).to eq(language_mode: 'unspecified', language: nil)
  end

  it 'does not let one confident article outvote text that cannot be judged, and still chooses automatic when two languages are known' do
    mixed_unknown = source_with(
      { title: '灯台だより', body: japanese_article },
      { title: 'Lighthouse notes', body: english_article },
      { title: 'Note', body: 'This unresolved note has several plain words today.' }
    )
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |method, text, account, **kwargs|
      next if text.include?('unresolved')

      method.call(text, account, **kwargs)
    end

    expect(described_class.attributes_for(mixed_unknown)).to eq(language_mode: 'auto', language: nil)
  end

  it 'reads at most the newest import page' do
    source = source_with
    limit = ExternalBridge::RSS::Limits::MAX_ITEMS
    (limit + 1).times do |index|
      ExternalResource.create!(
        external_source: source,
        protocol: 'rss',
        canonical_key: "page-#{index}",
        title: "Item #{index}",
        body: index == limit ? 'OLDEST-MARKER has several plain words today.' : "Newest #{index} has several plain words today.",
        published_at: index.hours.ago
      )
    end
    calls = []
    allow(LanguageDetector.instance).to receive(:detect).and_wrap_original do |_method, text, _account, **_kwargs|
      calls << text
      text.include?('OLDEST-MARKER') ? :ja : :en
    end

    expect(described_class.attributes_for(source)).to eq(language_mode: 'fixed', language: 'en')
    expect(calls.size).to eq(limit)
    expect(calls.join("\n")).not_to include('OLDEST-MARKER')
  end
end

RSpec.describe ExternalBridge::RSS::Subscribe do
  let(:user) { Fabricate(:user, locale: 'ja') }
  let(:other) { Fabricate(:user, locale: 'en') }
  let(:japanese_article) { '灯台の番人は青い紙の舟を数えて、嵐が来る前に手帳へ名前を書いた。海は静かに見えても、波はまだ遠くまで続いていた。' }
  let(:english_article) { 'Hello and welcome to the paper lighthouse how are you today?' }
  let(:feed_url) { 'https://feeds.example/initial-language.xml' }

  before do
    enable_external_bridge_rss!(user, other)
    user.settings['default_language'] = 'fr'
    redis.keys('external_bridge:rss:host:*').each { |key| redis.del(key) }
  end

  around do |example|
    previous_default = I18n.default_locale
    previous_locale = I18n.locale
    I18n.default_locale = :ja
    I18n.locale = :ja
    example.run
  ensure
    I18n.default_locale = previous_default
    I18n.locale = previous_locale
  end

  def japanese_feed
    rss_document(rss_item(guid: 'ja-1', title: '灯台だより', link: 'https://example.com/ja', body: japanese_article))
  end

  def languages_for(subscription)
    ids = ExternalStatusProjection.where(external_subscription_id: subscription.id).order(:id).pluck(:status_id)
    Status.where(id: ids).order(:id).pluck(:language)
  end

  it 'applies the same new-subscription rule on a fetch, a fresh cache, and a 304 before the first status' do
    stub_request(:get, feed_url).to_return(status: 200, body: japanese_feed, headers: { 'ETag' => 'W/"ja"' })

    created = described_class.new.call(user: user, url: feed_url)

    expect(created.language_mode).to eq('fixed')
    expect(created.language).to eq('ja')
    expect(languages_for(created)).to eq(['ja'])
    expect(a_request(:get, feed_url)).to have_been_made.once

    created.update!(language_mode: 'unspecified', language: nil)
    cached = described_class.new.call(user: other, url: feed_url)

    expect(a_request(:get, feed_url)).to have_been_made.once
    expect(cached.language_mode).to eq('fixed')
    expect(cached.language).to eq('ja')
    expect(languages_for(cached)).to eq(['ja'])
    expect(created.reload.language_mode).to eq('unspecified')
    expect(created.language).to be_nil

    created.external_source.update!(fetched_at: 1.hour.ago)
    third = Fabricate(:user, locale: 'en')
    enable_external_bridge_rss!(third)
    stub_request(:get, feed_url).to_return(status: 304, headers: { 'ETag' => 'W/"ignored"' })
    notarized = described_class.new.call(user: third, url: feed_url)

    expect(a_request(:get, feed_url)).to have_been_made.twice
    expect(notarized.language_mode).to eq('fixed')
    expect(notarized.language).to eq('ja')
    expect(languages_for(notarized)).to eq(['ja'])
    expect(created.reload.language_mode).to eq('unspecified')
    expect(cached.reload.language_mode).to eq('fixed')
    expect(cached.language).to eq('ja')
    expect(ExternalSource.column_names).not_to include('language_mode')
    expect(ExternalResource.column_names).not_to include('language')
  end

  it 'stores automatic for a mixed feed and keeps the minority language on the first statuses' do
    stub_request(:get, feed_url).to_return(
      status: 200,
      body: rss_document(
        rss_item(guid: 'ja-1', title: '灯台だより', link: 'https://example.com/ja', body: japanese_article) +
        rss_item(guid: 'ja-2', title: '灯台だより', link: 'https://example.com/ja-2', body: japanese_article) +
        rss_item(guid: 'en-1', title: 'Lighthouse notes', link: 'https://example.com/en', body: english_article)
      )
    )

    created = described_class.new.call(user: user, url: feed_url)

    expect(created.language_mode).to eq('auto')
    expect(created.language).to be_nil
    expect(languages_for(created)).to contain_exactly('ja', 'ja', 'en')
  end

  it 'stays unset for an empty feed or a short article and does not fall back to the interface language' do
    stub_request(:get, 'https://feeds.example/empty.xml').to_return(status: 200, body: rss_document(''))
    stub_request(:get, 'https://feeds.example/short.xml').to_return(
      status: 200,
      body: rss_document(rss_item(guid: 'short', title: 'Hi', link: 'https://example.com/short', body: ''))
    )

    empty = described_class.new.call(user: user, url: 'https://feeds.example/empty.xml')
    short = described_class.new.call(user: user, url: 'https://feeds.example/short.xml')

    expect(empty.language_mode).to eq('unspecified')
    expect(empty.language).to be_nil
    expect(languages_for(empty)).to eq([])
    expect(short.language_mode).to eq('unspecified')
    expect(short.language).to be_nil
    expect(languages_for(short)).to eq([nil])
  end

  it 'does not replace a saved choice on another subscribe, a refresh, a resume, or a deleting row' do
    stub_request(:get, feed_url).to_return(status: 200, body: japanese_feed, headers: { 'ETag' => 'W/"ja"' })
    created = described_class.new.call(user: user, url: feed_url)
    created.update!(language_mode: 'fixed', language: 'en')
    source = created.external_source
    source.update!(fetched_at: 2.hours.ago)
    stub_request(:get, feed_url).to_return(
      status: 200,
      body: rss_document(rss_item(guid: 'en-1', title: 'Lighthouse notes', link: 'https://example.com/en', body: english_article)),
      headers: { 'ETag' => 'W/"en"' }
    )

    expect(ExternalBridge::RSS::InitialLanguage).not_to receive(:attributes_for)
    described_class.new.call(user: user, url: feed_url)
    expect(created.reload.language_mode).to eq('fixed')
    expect(created.language).to eq('en')

    created.update!(language_mode: 'auto', language: nil, checked_at: 2.hours.ago)
    source.update!(fetched_at: 2.hours.ago)
    ExternalBridge::RSS::RefreshSource.new.call(source.id)
    expect(created.reload.language_mode).to eq('auto')
    expect(created.language).to be_nil

    created.update!(language_mode: 'unspecified', language: nil, state: 'paused')
    source.update!(fetched_at: 2.hours.ago)
    described_class.new.resume!(user: user, subscription_id: created.id)
    expect(created.reload.language_mode).to eq('unspecified')
    expect(created.language).to be_nil

    created.update_columns(state: 'deleting', language_mode: 'fixed', language: 'ja')
    expect { described_class.new.call(user: user, url: feed_url) }.to raise_error(ExternalBridge::Error) { |error|
      expect(error.code).to eq('subscription_deleting')
    }
    expect(created.reload.language_mode).to eq('fixed')
    expect(created.language).to eq('ja')
    expect(ExternalSubscription.where(user: other, external_source: source)).to be_empty
  end
end

# rubocop:enable Metrics/BlockLength
