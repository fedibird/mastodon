# frozen_string_literal: true

require 'rails_helper'

def translation_respecting_no_translate(texts)
  texts.map do |text|
    fragment = Nokogiri::HTML.fragment(text)
    fragment.xpath('.//text()').each do |node|
      next if node.ancestors.any? { |ancestor| ancestor.element? && ancestor['translate'] == 'no' }

      node.content = node.content.gsub('Hello', 'こんにちは').gsub('Fedibird', 'フェディバード').gsub('alice', 'アリス').gsub('bob', 'ボブ')
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
end
