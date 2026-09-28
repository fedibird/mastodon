# frozen_string_literal: true

require 'rails_helper'

def translation_respecting_no_translate(texts)
  texts.map do |text|
    fragment = Nokogiri::HTML.fragment(text)
    fragment.xpath('.//text()').each do |node|
      next if node.ancestors.any? { |ancestor| ancestor.element? && ancestor['translate'] == 'no' }

      node.content = node.content
                         .gsub('Hello', 'こんにちは')
                         .gsub(/fedibird/i, 'フェディバード')
                         .gsub(/mastodon/i, 'マストドン')
                         .gsub('NotATag', 'ノットアタグ')
                         .gsub('Lawsuit', 'ロースーツ')
                         .gsub('Ｓｙｎｔｈｗａｖｅ', 'シンセ')
                         .gsub('alice', 'アリス')
                         .gsub('bob', 'ボブ')
    end

    TranslationService::Translation.new(text: fragment.to_html, detected_source_language: 'en', provider: 'DeepL.com')
  end
end

RSpec.describe TranslateStatusService do
  let(:account) { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: account, text: 'Hello :blob: <script>alert(1)</script>', spoiler_text: 'Secret', language: 'en', visibility: :public) }
  let(:backend) { instance_double(TranslationService::DeepL) }

  before do
    Fabricate(:custom_emoji, shortcode: 'blob', domain: nil)
    allow(TranslationService).to receive(:configured?).and_return(true)
    allow(TranslationService).to receive(:configured).and_return(backend)
    allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
    allow(backend).to receive(:private_content_allowed?).and_return(false)
    allow(backend).to receive(:translate) do |texts, _source, _target|
      texts.map do |text|
        TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: 'DeepL.com')
      end
    end
    Rails.cache.clear
  end

  it 'translates content, spoiler, poll options, and media descriptions' do
    poll = Fabricate(:poll, status: status, options: ['Yes', 'No'])
    status.update!(poll_id: poll.id)
    media = Fabricate(:media_attachment, status: status, account: account, description: 'A cat &amp; dog')

    translation = described_class.new.call(status.reload, 'ja')

    expect(translation.content).to include('JA')
    expect(translation.content).to include(':blob:')
    expect(translation.content).not_to include('<script>')
    expect(translation.spoiler_text).to include('Secret')
    expect(translation.poll_options.map(&:title)).to include(a_string_including('Yes'), a_string_including('No'))
    expect(translation.media_attachments.map(&:id)).to eq [media.id]
    expect(translation.provider).to eq 'DeepL.com'
    expect(translation.detected_source_language).to eq 'en'
  end

  it 'preserves emoji shortcodes sent to the provider' do
    described_class.new.call(status, 'ja')

    expect(backend).to have_received(:translate).with(array_including(a_string_including('<span translate="no">:blob:</span>')), 'en', 'ja')
  end

  it 'wraps a shortcode that touches Japanese text before translation' do
    adjacent = Fabricate(:status, account: account, text: 'Hello', spoiler_text: '今日は:blob:です', language: 'en', visibility: :public)

    described_class.new.call(adjacent, 'ja')

    expect(backend).to have_received(:translate).with(
      array_including(a_string_including('今日は<span translate="no">:blob:</span>です')),
      'en',
      'ja'
    )
  end

  it 'reapplies compatible boundaries when a translation returns a bare shortcode' do
    adjacent = Fabricate(:status, account: account, text: '今日は:blob:です', spoiler_text: 'CW:blob:test', language: 'en', visibility: :public)
    allow(backend).to receive(:translate) do |_texts, _source, _target|
      [
        TranslationService::Translation.new(text: '今日は:blob:です', detected_source_language: 'en', provider: 'DeepL.com'),
        TranslationService::Translation.new(text: 'CW:blob:test', detected_source_language: 'en', provider: 'DeepL.com'),
      ]
    end

    translation = described_class.new.call(adjacent, 'ja')

    expect(translation.content).to include("今日は\u200B:blob:\u200Bです")
    expect(translation.spoiler_text).to eq("CW\u200B:blob:\u200Btest")
  end

  it 'wraps a body shortcode without rewriting the same shortcode inside an href' do
    linked = Fabricate(:status, account: account, text: 'See https://example.com/x/:blob:/y and :blob:', language: 'en', visibility: :public)

    described_class.new.call(linked, 'ja')

    html = nil
    expect(backend).to have_received(:translate) do |texts, _source, _target|
      html = texts.first
    end
    fragment = Nokogiri::HTML.fragment(html)
    expect(fragment.at_css('a')['href']).to eq 'https://example.com/x/:blob:/y'
    expect(fragment.at_css('a')['href']).not_to include('<span')
    expect(fragment.css('span[translate="no"]').map(&:text)).to include(':blob:')
  end

  it 'translates a reblog from the boosted status content and protects its emoji' do
    original = Fabricate(:status, text: 'Original :blob:', language: 'en', visibility: :public)
    reblog = Fabricate(:status, reblog: original, text: '', visibility: :public)

    described_class.new.call(reblog, 'ja')

    expect(reblog.language).to be_nil
    expect(backend).to have_received(:translate).with(
      array_including(a_string_including('Original').and(a_string_including('<span translate="no">:blob:</span>'))),
      nil,
      'ja'
    )
  end

  it 'refuses a non-distributable status' do
    status.update!(visibility: :direct)

    expect { described_class.new.call(status, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'allows public and unlisted statuses and rejects every other visibility' do
    expect(Status.visibilities.keys).to match_array(%w(public unlisted private direct limited mutual personal))

    Status.visibilities.each_key do |visibility|
      example = Fabricate(:status, account: account, text: "Hello #{visibility}", language: 'en', visibility: visibility)

      if example.distributable?
        expect(described_class.new.call(example, 'ja').content).to include('JA')
      else
        expect { described_class.new.call(example, 'ja') }.to raise_error(Mastodon::NotPermittedError)
      end
    end

    expect(backend).to have_received(:translate).twice
  end

  it 'falls back from a regional source language to the provider primary language' do
    regional = Fabricate(:status, account: account, text: '你好', language: 'zh-CN', visibility: :public)
    allow(backend).to receive(:languages).and_return('en' => ['ja'], 'zh' => ['ja'], nil => ['ja'])

    described_class.new.call(regional, 'ja')

    expect(backend).to have_received(:translate).with(anything, 'zh', 'ja')
  end

  it 'does not collapse a non-region source subtag into the primary language' do
    cantonese = Fabricate(:status, account: account, text: '你好', language: 'zh-YUE', visibility: :public)
    allow(backend).to receive(:languages).and_return('en' => ['ja'], 'zh' => ['ja'], nil => ['ja'])

    expect { described_class.new.call(cantonese, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  def chinese_script_languages
    { 'zh-Hans' => ['ja'], 'zh-Hant' => ['ja'], nil => ['ja'] }
  end

  def translation_cache_keys
    keys = []
    allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, key, *args, &block|
      keys << key if key.is_a?(String) && key.start_with?('v3:translations/')
      method.call(key, *args, &block)
    end
    keys
  end

  it 'uses provider auto detection for bare zh when only Chinese script tags are available' do
    chinese = Fabricate(:status, account: account, text: '你好', language: 'zh', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages)

    described_class.new.call(chinese, 'ja')

    expect(backend).to have_received(:translate).with(anything, nil, 'ja')
  end

  it 'maps zh-CN to zh-Hans when the provider exposes that script tag' do
    regional = Fabricate(:status, account: account, text: '你好', language: 'zh-CN', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages.merge('zh' => ['ja']))

    described_class.new.call(regional, 'ja')

    expect(backend).to have_received(:translate).with(anything, 'zh-Hans', 'ja')
  end

  it 'maps zh-TW to zh-Hant when the provider exposes that script tag' do
    regional = Fabricate(:status, account: account, text: '你好', language: 'zh-TW', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages.merge('zh' => ['ja']))

    described_class.new.call(regional, 'ja')

    expect(backend).to have_received(:translate).with(anything, 'zh-Hant', 'ja')
  end

  it 'maps the other Chinese region tags onto the matching script tag' do
    received_sources = []
    allow(backend).to receive(:languages).and_return(chinese_script_languages)
    allow(backend).to receive(:translate) do |texts, source, _target|
      received_sources << source
      texts.map { |text| TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'zh', provider: 'LibreTranslate') }
    end

    mappings = {
      'zh-SG' => 'zh-Hans',
      'zh-HK' => 'zh-Hant',
      'zh-MO' => 'zh-Hant',
      'zh-cn' => 'zh-Hans',
      'zh_TW' => 'zh-Hant',
      'zh-hans' => 'zh-Hans',
      'ZH-HANT' => 'zh-Hant',
    }

    mappings.each_key do |status_language|
      regional = Fabricate(:status, account: account, text: "你好 #{status_language}", language: status_language, visibility: :public)
      described_class.new.call(regional, 'ja')
    end

    expect(received_sources).to eq mappings.values
  end

  it 'keeps an exact zh provider key instead of auto detection' do
    chinese = Fabricate(:status, account: account, text: '你好', language: 'zh', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages.merge('zh' => ['ja']))

    described_class.new.call(chinese, 'ja')

    expect(backend).to have_received(:translate).with(anything, 'zh', 'ja')
  end

  it 'does not collapse zh-YUE into a Chinese script tag or auto detection' do
    cantonese = Fabricate(:status, account: account, text: '你好', language: 'zh-YUE', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages)

    expect { described_class.new.call(cantonese, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'does not auto-detect bare zh when the provider has no Chinese script tags' do
    chinese = Fabricate(:status, account: account, text: '你好', language: 'zh', visibility: :public)
    allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])

    expect { described_class.new.call(chinese, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'does not force a Chinese region alias or auto detection when the script tag is missing' do
    regional = Fabricate(:status, account: account, text: '你好', language: 'zh-CN', visibility: :public)
    allow(backend).to receive(:languages).and_return('zh-Hant' => ['ja'], nil => ['ja'])

    expect { described_class.new.call(regional, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'memoizes a nil source language so auto detection is not resolved again' do
    chinese = Fabricate(:status, account: account, text: '你好', language: 'zh', visibility: :public)
    allow(backend).to receive(:languages).and_return(chinese_script_languages)
    service = described_class.new
    service.instance_variable_set(:@status, chinese)
    resolutions = 0
    allow(service).to receive(:resolved_source_language).and_wrap_original do |method, *args|
      resolutions += 1
      method.call(*args)
    end

    2.times { expect(service.send(:source_language)).to be_nil }

    expect(resolutions).to eq 1
    expect(service.instance_variable_defined?(:@source_language)).to be true
  end

  it 'refuses an unsupported language pair' do
    expect { described_class.new.call(status, 'de') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'refuses translation when no provider is configured' do
    allow(TranslationService).to receive(:configured?).and_return(false)

    expect { described_class.new.call(status, 'ja') }.to raise_error(Mastodon::NotPermittedError)
  end

  it 'reuses the cache until the status content changes' do
    described_class.new.call(status, 'ja')
    described_class.new.call(status, 'ja')
    status.update!(text: 'Edited hello')
    described_class.new.call(status, 'ja')

    expect(backend).to have_received(:translate).twice
  end

  it 'keys the cache by the effective provider source, target, and content hash' do
    allow(backend).to receive(:languages).and_return('en' => %w(ja de), 'fr' => ['ja'], nil => ['ja'])
    keys = translation_cache_keys

    described_class.new.call(status, 'ja')
    described_class.new.call(status, 'ja', source_language: 'en', explicit_source: true)
    described_class.new.call(status, 'de')
    described_class.new.call(status, 'ja', source_language: 'fr', explicit_source: true)

    expect(keys.grep(%r{\Av3:translations/en/ja/}).uniq.size).to eq 1
    expect(keys).to include(a_string_matching(%r{\Av3:translations/en/de/}))
    expect(keys).to include(a_string_matching(%r{\Av3:translations/fr/ja/}))
    expect(backend).to have_received(:translate).exactly(3).times
    expect(status.reload.language).to eq 'en'
  end

  it 'uses a stable auto token so a nil source does not collide with another source' do
    detected = Fabricate(:status, account: account, text: 'Hello :blob: <script>alert(1)</script>', spoiler_text: 'Secret', language: nil, visibility: :public)
    keys = translation_cache_keys

    described_class.new.call(detected, 'ja')
    described_class.new.call(detected, 'ja', source_language: 'und', explicit_source: true)
    described_class.new.call(detected, 'ja', source_language: 'en', explicit_source: true)

    expect(keys.grep(%r{\Av3:translations/auto/ja/}).uniq.size).to eq 1
    expect(keys).to include(a_string_matching(%r{\Av3:translations/en/ja/}))
    expect(keys).not_to include(a_string_matching(%r{\Av3:translations//}))
    expect(backend).to have_received(:translate).with(anything, nil, 'ja').once
    expect(backend).to have_received(:translate).with(anything, 'en', 'ja').once
    expect(detected.reload.language).to be_nil
  end

  it 'resolves an explicit source with the same Chinese rules and sends und as auto detection' do
    allow(backend).to receive(:languages).and_return(chinese_script_languages)

    described_class.new.call(status, 'ja', source_language: 'zh-CN', explicit_source: true)
    described_class.new.call(status, 'ja', source_language: 'zh-Hans', explicit_source: true)
    described_class.new.call(status, 'ja', source_language: 'UND', explicit_source: true)

    expect(backend).to have_received(:translate).with(anything, 'zh-Hans', 'ja').once
    expect(backend).to have_received(:translate).with(anything, nil, 'ja').once
    expect(status.reload.language).to eq 'en'
  end

  it 'rejects an explicit unsupported pair without treating it as an authorization failure' do
    expect { described_class.new.call(status, 'de', explicit_target: true) }.to raise_error(Mastodon::ValidationError)
    expect { described_class.new.call(status, 'ja', source_language: 'fr', explicit_source: true) }.to raise_error(Mastodon::ValidationError)
    expect { described_class.new.call(status, 'ja', source_language: 'und', explicit_source: true) }.not_to raise_error
    allow(backend).to receive(:languages).and_return('en' => ['ja'])
    Rails.cache.clear

    expect { described_class.new.call(status, 'ja', source_language: 'und', explicit_source: true) }.to raise_error(Mastodon::ValidationError)
    expect(backend).to have_received(:translate).once
  end

  it 'still refuses private content and a missing provider when the pair is explicit' do
    status.update!(visibility: :direct)

    expect { described_class.new.call(status, 'ja', source_language: 'en', explicit_source: true, explicit_target: true) }.to raise_error(Mastodon::NotPermittedError)

    status.update!(visibility: :public)
    allow(TranslationService).to receive(:configured?).and_return(false)

    expect { described_class.new.call(status, 'ja', source_language: 'en', explicit_source: true) }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'protects formatted hashtags and keeps the tag after translation' do
    tagged = Fabricate(:status, account: account, text: 'Hello #Fedibird', spoiler_text: 'CW #Fedibird', language: 'en', visibility: :public)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(tagged, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) do |texts, _source, _target|
      sent = texts.first
      spoiler = Nokogiri::HTML.fragment(texts[1])
      expect(spoiler.css('a')).to be_empty
      expect(spoiler.text).to include('#Fedibird')
    end

    fragment = Nokogiri::HTML.fragment(sent)
    hashtag = fragment.at_css('a.hashtag')

    expect(hashtag['translate']).to eq 'no'
    expect(hashtag.text).to eq '#Fedibird'
    expect(hashtag['class']).to include('hashtag')
    expect(hashtag['rel']).to include('tag')
    expect(hashtag['href'].downcase).to include('fedibird')
    expect(hashtag['href']).not_to include('<')
    expect(hashtag.parent['translate']).not_to eq 'no'

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.hashtag')

    expect(translation.content).to include('こんにちは')
    expect(restored.text).to eq '#Fedibird'
    expect(restored['translate']).to be_nil
    expect(restored['class']).to include('hashtag')
    expect(restored['href'].downcase).to include('fedibird')
    expect(result.css('span[translate="no"]')).to be_empty
    expect(translation.content).not_to include('フェディバード')
    expect(translation.spoiler_text).to include('フェディバード')
  end

  it 'protects hashtags alongside custom emoji and mentions' do
    bob = Fabricate(:account, username: 'bob')
    mixed = Fabricate(:status, account: account, text: 'Hello @bob :blob: #Fedibird', language: 'en', visibility: :public)
    Fabricate(:mention, account: bob, status: mixed)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(mixed, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    hashtag = fragment.at_css('a.hashtag')

    mention = fragment.at_css('span.h-card a.mention')

    expect(fragment.at_css('span.h-card')['translate']).to eq 'no'
    expect(mention['translate']).not_to eq 'no'
    expect(mention['class']).not_to include('hashtag')
    expect(mention.text).to include('bob')
    expect(fragment.css('span[translate="no"]').map(&:text)).to include(':blob:')
    expect(hashtag['translate']).to eq 'no'
    expect(hashtag['class']).to include('mention')
    expect(hashtag['class']).to include('hashtag')
    expect(hashtag['rel']).to include('tag')
    expect(hashtag.text).to eq '#Fedibird'
    expect(hashtag['href']).not_to include('<span')
    expect(hashtag.parent['translate']).not_to eq 'no'

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.hashtag')

    expect(result.at_css('span.h-card')).to be_present
    expect(result.at_css('span.h-card')['translate']).to be_nil
    expect(result.at_css('span.h-card a.mention').text).to include('bob')
    expect(translation.content).to include('こんにちは')
    expect(translation.content).not_to include('ボブ')
    expect(restored.text).to eq '#Fedibird'
    expect(restored['translate']).to be_nil
    expect(restored['class']).to include('hashtag')
    expect(translation.content).to include(':blob:')
    expect(result.css('span[translate="no"]')).to be_empty
  end

  it 'does not protect ordinary links' do
    linked = Fabricate(:status, account: account, text: 'Visit https://example.com/ today', language: 'en', visibility: :public)

    described_class.new.call(linked, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    link = fragment.css('a').find { |anchor| anchor['href']&.include?('https://example.com/') }

    expect(link).to be_present
    expect(link['translate']).not_to eq 'no'
    expect(link['class'].to_s).not_to include('hashtag')
    expect(link.ancestors.none? { |node| node.element? && node['translate'] == 'no' }).to be true
    expect(fragment.css('span[translate="no"]')).to be_empty
  end

  describe 'provider trust' do
    let(:translate_calls) { [] }

    before do
      allow(TranslationService).to receive(:configured?).and_call_original
      allow(TranslationService).to receive(:configured).and_wrap_original do |original, *args|
        selected = original.call(*args)
        allow(selected).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
        allow(selected).to receive(:translate) do |texts, _source, _target|
          translate_calls << selected
          texts.map do |text|
            TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: selected.class.name)
          end
        end
        selected
      end
    end

    def with_translation_env(env)
      ClimateControl.modify({
        DEEPL_API_KEY: nil,
        DEEPL_PLAN: nil,
        LIBRE_TRANSLATE_ENDPOINT: nil,
        LIBRE_TRANSLATE_API_KEY: nil,
        LIBRE_TRANSLATE_ALLOW_PRIVATE: nil,
      }.merge(env)) do
        Rails.cache.clear
        translate_calls.clear
        yield
      end
    end

    def call_status(visibility, target = 'ja')
      example = Fabricate(:status, account: account, text: "Hello #{visibility} #{target}", language: 'en', visibility: visibility)
      described_class.new.call(example, target)
    end

    it 'rejects non-distributable statuses for an untrusted LibreTranslate endpoint' do
      [nil, '', 'false'].each do |flag|
        with_translation_env(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: flag) do
          expect(TranslationService.configured).to be_a(TranslationService::LibreTranslate)
          expect(call_status(:public).content).to include('JA')
          expect(call_status(:unlisted).content).to include('JA')
          %w(private direct limited mutual personal).each do |visibility|
            expect { call_status(visibility) }.to raise_error(Mastodon::NotPermittedError)
          end
          expect(translate_calls.size).to eq 2
        end
      end
    end

    it 'translates every visibility through trusted LibreTranslate and still rejects an unsupported language' do
      with_translation_env(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        expect(TranslationService.configured).to be_a(TranslationService::LibreTranslate)
        expect(TranslationService.private_content_allowed?).to be true

        %w(public unlisted private direct limited mutual personal).each do |visibility|
          expect(call_status(visibility).content).to include('JA')
        end

        expect { call_status(:private, 'de') }.to raise_error(Mastodon::NotPermittedError)
        expect(translate_calls.size).to eq Status.visibilities.size
      end
    end

    it 'keeps the existing cache for a trusted private translation' do
      with_translation_env(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        hidden = Fabricate(:status, account: account, text: 'Hello', language: 'en', visibility: :direct)

        described_class.new.call(hidden, 'ja')
        described_class.new.call(hidden, 'ja')

        expect(translate_calls.size).to eq 1
      end
    end

    it 'rejects non-distributable statuses when DeepL is selected, even if the flag is true' do
      with_translation_env(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        expect(TranslationService.configured).to be_a(TranslationService::DeepL)
        expect(TranslationService.private_content_allowed?).to be false
        expect(call_status(:public).content).to include('JA')
        %w(private direct limited mutual personal).each do |visibility|
          expect { call_status(visibility) }.to raise_error(Mastodon::NotPermittedError)
        end
        expect(translate_calls.size).to eq 1
      end
    end

    it 'selects DeepL and rejects private content when both providers and the flag are set' do
      with_translation_env(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        expect(TranslationService.configured).to be_a(TranslationService::DeepL)
        expect(TranslationService.private_content_allowed?).to be false
        expect(call_status(:public).content).to include('JA')
        expect(call_status(:unlisted).content).to include('JA')
        %w(private direct).each do |visibility|
          expect { call_status(visibility) }.to raise_error(Mastodon::NotPermittedError)
        end
        expect(translate_calls.map(&:class).uniq).to eq [TranslationService::DeepL]
      end
    end
  end

  it 'protects a hashtag already present in remote content' do
    remote_account = Fabricate(:account, domain: 'remote.test', username: 'carol')
    remote_html = '<p>Hello <a href="https://remote.test/tags/Fedibird" class="mention hashtag" rel="tag">#<span>Fedibird</span></a></p>'
    remote = Fabricate(:status, account: remote_account, text: remote_html, local: false, language: 'en', visibility: :public)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(remote, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    hashtag = fragment.at_css('a.hashtag')

    expect(remote.local?).to be false
    expect(remote.tags).to be_empty
    expect(hashtag['translate']).to eq 'no'
    expect(hashtag['class']).to include('hashtag')
    expect(hashtag.text).to include('Fedibird')
    expect(hashtag['href']).to include('https://remote.test/tags/Fedibird')

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.hashtag')
    expect(restored.text).to include('Fedibird')
    expect(restored['translate']).to be_nil
    expect(restored['class']).to include('mention')
    expect(restored.parent['translate']).not_to eq 'no'
    expect(result.css('[translate]')).to be_empty
    expect(translation.content).not_to include('フェディバード')
  end

  it 'protects a local mention and leaves the surrounding text translatable' do
    bob = Fabricate(:account, username: 'bob')
    mentioned = Fabricate(:status, account: account, text: 'Hello @bob', language: 'en', visibility: :public)
    Fabricate(:mention, account: bob, status: mentioned)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(mentioned, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    card = fragment.at_css('span.h-card')
    mention = card.at_css('a.mention')

    expect(card['translate']).to eq 'no'
    expect(mention['translate']).not_to eq 'no'
    expect(mention['class']).to include('mention')
    expect(mention['class']).not_to include('hashtag')
    expect(mention['data-account-id']).to eq bob.id.to_s
    expect(mention.text).to include('bob')
    expect(fragment.at_xpath('.//text()[contains(., "Hello")]').ancestors.none? { |node| node.element? && node['translate'] == 'no' }).to be true

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.mention')

    expect(translation.content).to include('こんにちは')
    expect(restored.text).to include('bob')
    expect(translation.content).not_to include('ボブ')
    expect(restored['href']).to eq mention['href']
    expect(restored['class']).to include('mention')
    expect(result.at_css('span.h-card')).to be_present
    expect(result.css('[translate]')).to be_empty
  end

  it 'protects a remote h-card mention that was stored without translate="no"' do
    remote_account = Fabricate(:account, domain: 'remote.test', username: 'carol')
    remote_html = '<p>Hello <span class="h-card"><a href="https://remote.test/@alice" class="u-url mention">@<span>alice</span></a></span></p>'
    remote = Fabricate(:status, account: remote_account, text: remote_html, local: false, language: 'en', visibility: :public)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(remote, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    card = fragment.at_css('span.h-card')
    mention = card.at_css('a.mention')

    expect(remote.local?).to be false
    expect(remote_html).not_to include('translate')
    expect(card['translate']).to eq 'no'
    expect(mention['translate']).not_to eq 'no'
    expect(mention['href']).to eq 'https://remote.test/@alice'
    expect(mention.text).to include('alice')

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.mention')

    expect(translation.content).to include('こんにちは')
    expect(restored.text).to include('alice')
    expect(translation.content).not_to include('アリス')
    expect(restored['href']).to eq 'https://remote.test/@alice'
    expect(restored['class']).to include('mention')
    expect(result.at_css('span.h-card')).to be_present
    expect(result.at_css('span.h-card')['class']).to include('h-card')
    expect(result.css('[translate]')).to be_empty
  end

  it 'protects a remote mention anchor that has no h-card wrapper' do
    remote_account = Fabricate(:account, domain: 'remote.test', username: 'carol')
    remote_html = '<p>Hello <a href="https://remote.test/@alice" class="mention">@alice</a></p>'
    remote = Fabricate(:status, account: remote_account, text: remote_html, local: false, language: 'en', visibility: :public)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(remote, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    mention = fragment.at_css('a.mention')

    expect(fragment.at_css('span.h-card')).to be_nil
    expect(mention['translate']).to eq 'no'
    expect(mention['class']).not_to include('hashtag')
    expect(mention['href']).to eq 'https://remote.test/@alice'
    expect(mention.text).to include('alice')

    result = Nokogiri::HTML.fragment(translation.content)
    restored = result.at_css('a.mention')

    expect(translation.content).to include('こんにちは')
    expect(restored.text).to include('alice')
    expect(translation.content).not_to include('アリス')
    expect(restored['href']).to eq 'https://remote.test/@alice'
    expect(restored['class']).to include('mention')
    expect(restored['translate']).to be_nil
    expect(result.css('[translate]')).to be_empty
  end

  it 'protects a mention and a hashtag without treating the hashtag as a user mention' do
    bob = Fabricate(:account, username: 'bob')
    mixed = Fabricate(:status, account: account, text: 'Hello @bob #Fedibird', language: 'en', visibility: :public)
    Fabricate(:mention, account: bob, status: mixed)
    allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }

    translation = described_class.new.call(mixed, 'ja')

    sent = nil
    expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
    fragment = Nokogiri::HTML.fragment(sent)
    card = fragment.at_css('span.h-card')
    mention = card.at_css('a.mention')
    hashtag = fragment.at_css('a.hashtag')

    expect(card['translate']).to eq 'no'
    expect(mention['translate']).not_to eq 'no'
    expect(mention['class']).not_to include('hashtag')
    expect(hashtag['translate']).to eq 'no'
    expect(hashtag['class']).to include('mention')
    expect(hashtag['class']).to include('hashtag')
    expect(hashtag.parent['translate']).not_to eq 'no'
    expect(card.css('a.hashtag')).to be_empty

    result = Nokogiri::HTML.fragment(translation.content)

    expect(translation.content).to include('こんにちは')
    expect(result.at_css('span.h-card a.mention').text).to include('bob')
    expect(result.at_css('a.hashtag').text).to include('Fedibird')
    expect(translation.content).not_to include('ボブ')
    expect(translation.content).not_to include('フェディバード')
    expect(result.css('[translate]')).to be_empty
  end

  describe 'hashtags recorded on the status' do
    def remote_status(html)
      remote_account = Fabricate(:account, domain: 'remote.test')
      Fabricate(:status, account: remote_account, text: html, local: false, language: 'en', visibility: :public)
    end

    def sent_html
      sent = nil
      expect(backend).to have_received(:translate) { |texts, _source, _target| sent = texts.first }
      sent
    end

    before do
      allow(backend).to receive(:translate) { |texts, _source, _target| translation_respecting_no_translate(texts) }
    end

    it 'protects a remote hashtag anchor that has no hashtag class' do
      remote = remote_status('<p>Hello <a href="https://remote.test/tags/Fedibird">#Fedibird</a></p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      anchor = fragment.at_css('a')

      expect(anchor['translate']).to eq 'no'
      expect(anchor['class'].to_s).not_to include('hashtag')
      expect(anchor['href']).to eq 'https://remote.test/tags/Fedibird'
      expect(anchor.text).to eq '#Fedibird'

      result = Nokogiri::HTML.fragment(translation.content)
      expect(translation.content).to include('こんにちは')
      expect(result.at_css('a').text).to eq '#Fedibird'
      expect(result.at_css('a')['href']).to eq 'https://remote.test/tags/Fedibird'
      expect(translation.content).not_to include('フェディバード')
      expect(result.css('[translate]')).to be_empty
    end

    it 'wraps only the recorded hashtag when an anchor also contains other text' do
      remote = remote_status('<p><a href="https://example.com/article">Hello #Fedibird world</a></p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      anchor = fragment.at_css('a')
      protected_tag = anchor.at_css('span[translate="no"]')

      expect(anchor['translate']).to be_nil
      expect(anchor['href']).to eq 'https://example.com/article'
      expect(protected_tag.text).to eq '#Fedibird'
      expect(anchor.text).to include('Hello')
      expect(anchor.text).to include('world')

      result = Nokogiri::HTML.fragment(translation.content)
      result_anchor = result.at_css('a')

      expect(result_anchor.text).to include('こんにちは')
      expect(result_anchor.text).to include('#Fedibird')
      expect(result_anchor.text).to include('world')
      expect(result_anchor['href']).to eq 'https://example.com/article'
      expect(result_anchor['translate']).to be_nil
      expect(translation.content).not_to include('フェディバード')
      expect(result.css('[translate]')).to be_empty
    end

    it 'protects a hashtag after Formatter replaces rel="tag"' do
      remote = remote_status('<p>Hello <a rel="tag" href="https://remote.test/tags/Fedibird">#Fedibird</a></p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')
      formatted = Nokogiri::HTML.fragment(Formatter.instance.format(remote, rest: true, emoji_compatibility: true))
      formatted_anchor = formatted.at_css('a')

      expect(formatted_anchor['rel'].to_s.split).not_to include('tag')
      expect(formatted_anchor['href']).to eq 'https://remote.test/tags/Fedibird'
      expect(formatted_anchor['class'].to_s).not_to include('hashtag')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      anchor = fragment.at_css('a')

      expect(anchor['translate']).to eq 'no'
      expect(anchor['href']).to eq 'https://remote.test/tags/Fedibird'

      result = Nokogiri::HTML.fragment(translation.content)
      expect(result.at_css('a').text).to eq '#Fedibird'
      expect(result.at_css('a')['href']).to eq 'https://remote.test/tags/Fedibird'
      expect(translation.content).not_to include('フェディバード')
      expect(result.css('[translate]')).to be_empty
    end

    it 'wraps a plain-text hashtag that is recorded on the status' do
      remote = remote_status('<p>Hello #Fedibird world</p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      protected_tag = fragment.at_css('span[translate="no"]')

      expect(protected_tag.text).to eq '#Fedibird'
      expect(protected_tag.parent.text).to include('Hello')
      expect(protected_tag.parent.text).to include('world')

      result = Nokogiri::HTML.fragment(translation.content)
      expect(result.text).to include('こんにちは')
      expect(result.text).to include('#Fedibird')
      expect(result.text).to include('world')
      expect(result.text).not_to include('フェディバード')
      expect(result.css('span')).to be_empty
      expect(result.css('[translate]')).to be_empty
    end

    it 'does not protect a hash token that is not recorded on the status' do
      sent = []
      allow(backend).to receive(:translate) do |texts, _source, _target|
        sent << texts.first
        translation_respecting_no_translate(texts)
      end

      remote = remote_status('<p>Hello #NotATag</p>')
      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent.last)

      expect(remote.tags).to be_empty
      expect(fragment.css('[translate]')).to be_empty
      expect(translation.content).to include('ノットアタグ')

      classed = remote_status('<p>Hello <a href="https://remote.test/tags/NotATag" class="mention hashtag" rel="tag">#<span>NotATag</span></a></p>')
      classed_translation = described_class.new.call(classed, 'ja')
      classed_anchor = Nokogiri::HTML.fragment(sent.last).at_css('a.hashtag')

      expect(classed.tags).to be_empty
      expect(classed_anchor['translate']).to eq 'no'
      expect(classed_translation.content).to include('NotATag')
      expect(classed_translation.content).not_to include('ノットアタグ')
      expect(Nokogiri::HTML.fragment(classed_translation.content).css('[translate]')).to be_empty
    end

    it 'protects only the recorded tags when several plain-text hashtags are present' do
      sent = []
      allow(backend).to receive(:translate) do |texts, _source, _target|
        sent << texts.first
        translation_respecting_no_translate(texts)
      end

      both = remote_status('<p>#Fedibird #Mastodon</p>')
      both.tags << Fabricate(:tag, name: 'Fedibird')
      both.tags << Fabricate(:tag, name: 'Mastodon')

      described_class.new.call(both, 'ja')
      both_fragment = Nokogiri::HTML.fragment(sent.last)

      expect(both_fragment.css('span[translate="no"]').map(&:text)).to eq ['#Fedibird', '#Mastodon']

      one = remote_status('<p>#Fedibird #Mastodon</p>')
      one.tags << Tag.find_normalized('Fedibird')
      one_translation = described_class.new.call(one, 'ja')
      one_fragment = Nokogiri::HTML.fragment(sent.last)

      expect(one.tags.map { |tag| HashtagNormalizer.new.normalize(tag.name) }).to eq ['fedibird']
      expect(one_fragment.css('span[translate="no"]').map(&:text)).to eq ['#Fedibird']
      expect(one_translation.content).to include('#Fedibird')
      expect(one_translation.content).to include('マストドン')
      expect(one_translation.content).not_to include('フェディバード')
      expect(Nokogiri::HTML.fragment(one_translation.content).css('[translate]')).to be_empty
    end

    it 'protects a recorded hashtag when only the letter case differs' do
      remote = remote_status('<p>Hello #fedibird</p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)

      expect(HashtagNormalizer.new.normalize('fedibird')).to eq HashtagNormalizer.new.normalize('Fedibird')
      expect(fragment.at_css('span[translate="no"]').text).to eq '#fedibird'
      expect(translation.content).to include('#fedibird')
      expect(translation.content).not_to include('フェディバード')
      expect(Nokogiri::HTML.fragment(translation.content).css('[translate]')).to be_empty
    end

    it 'protects a recorded hashtag whose letters use a different Unicode width' do
      remote = remote_status('<p>Hello #Ｓｙｎｔｈｗａｖｅ</p>')
      remote.tags << Fabricate(:tag, name: 'synthwave')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)

      expect(HashtagNormalizer.new.normalize('Ｓｙｎｔｈｗａｖｅ')).to eq 'synthwave'
      expect(fragment.at_css('span[translate="no"]').text).to eq '#Ｓｙｎｔｈｗａｖｅ'
      expect(translation.content).to include('#Ｓｙｎｔｈｗａｖｅ')
      expect(translation.content).not_to include('シンセ')
      expect(Nokogiri::HTML.fragment(translation.content).css('[translate]')).to be_empty
    end

    it 'protects a recorded hashtag written with a fullwidth hash sign' do
      remote = remote_status('<p>Hello ＃Ｓｙｎｔｈｗａｖｅ</p>')
      remote.tags << Fabricate(:tag, name: 'synthwave')

      translation = described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      protected_tag = fragment.at_css('span[translate="no"]')

      expect(protected_tag.text).to eq '＃Ｓｙｎｔｈｗａｖｅ'
      expect(translation.content).to include('こんにちは')
      expect(translation.content).to include('＃Ｓｙｎｔｈｗａｖｅ')
      expect(translation.content).not_to include('シンセ')
      expect(Nokogiri::HTML.fragment(translation.content).css('[translate]')).to be_empty
    end

    it 'does not rewrite a hashtag that only appears inside a URL' do
      remote = remote_status('<p>Hello <a href="https://example.com/wiki/Page#Fedibird">example</a> #Fedibird</p>')
      remote.tags << Fabricate(:tag, name: 'Fedibird')
      remote.tags << Fabricate(:tag, name: 'Lawsuit')

      described_class.new.call(remote, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)
      anchor = fragment.at_css('a')

      expect(anchor['href']).to eq 'https://example.com/wiki/Page#Fedibird'
      expect(anchor['href']).not_to include('<span')
      expect(anchor['translate']).not_to eq 'no'
      expect(fragment.css('span[translate="no"]').map(&:text)).to eq ['#Fedibird']
    end

    it 'protects a plain-text hashtag on the boosted status when translating a reblog' do
      original = remote_status('<p>Hello #Fedibird world</p>')
      original.tags << Fabricate(:tag, name: 'Fedibird')
      reblog = Fabricate(:status, reblog: original, text: '', visibility: :public)

      described_class.new.call(reblog, 'ja')
      fragment = Nokogiri::HTML.fragment(sent_html)

      expect(reblog.tags).to be_empty
      expect(fragment.at_css('span[translate="no"]').text).to eq '#Fedibird'
    end

    it 'uses the existing content hash when protected hashtag markup changes' do
      remote = remote_status('<p>Hello #Fedibird world</p>')
      allow(backend).to receive(:translate) do |texts, _source, _target|
        texts.map { |text| TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: 'DeepL.com') }
      end

      described_class.new.call(remote, 'ja')
      described_class.new.call(remote, 'ja')
      remote.tags << Fabricate(:tag, name: 'Fedibird')
      described_class.new.call(remote, 'ja')

      expect(backend).to have_received(:translate).twice
    end
  end
end
