# frozen_string_literal: true

require 'rails_helper'

def assert_deepl_translation_timeouts(url)
  body = Oj.dump(translations: [{ text: 'Hello', detected_source_language: 'JA' }])

  ClimateControl.modify(TRANSLATION_TIMEOUT: nil) do
    expect(Request).to receive(:new).with(:post, url, hash_excluding(:timeout_options)).and_wrap_original do |method, *args, **kwargs|
      request = method.call(*args, **kwargs)
      timeouts = request.instance_variable_get(:@options)[:timeout_options]
      expect(timeouts[:read_timeout]).to eq 10
      expect(timeouts[:read_deadline]).to eq 30
      request
    end
    stub_request(:post, url).to_return(status: 200, body: body)
    yield
  end

  ClimateControl.modify(TRANSLATION_TIMEOUT: '30') do
    expect(Request).to receive(:new).with(:post, url, hash_including(timeout_options: { read_timeout: 30, read_deadline: 30 })).and_call_original
    stub_request(:post, url).to_return(status: 200, body: body)
    yield
  end
end

RSpec.describe TranslationService::DeepL do
  subject { described_class.new('free', 'deepl-secret') }

  let(:base) { 'https://api-free.deepl.com' }

  describe '#translate' do
    it 'returns translated text and the detected source language' do
      stub_request(:post, "#{base}/v2/translate").to_return(
        status: 200,
        body: Oj.dump(translations: [{ text: 'Hello', detected_source_language: 'JA' }])
      )

      result = subject.translate(['こんにちは'], 'ja', 'en')

      expect(result.first.text).to eq 'Hello'
      expect(result.first.detected_source_language).to eq 'ja'
      expect(result.first.provider).to eq 'DeepL.com'
      expect(WebMock).to have_requested(:post, "#{base}/v2/translate").with { |request|
        request.body.include?('tag_handling=html') && !request.body.include?('deepl-secret')
      }
    end

    it 'passes a translation timeout only when TRANSLATION_TIMEOUT is set' do
      assert_deepl_translation_timeouts("#{base}/v2/translate") { subject.translate(['こんにちは'], 'ja', 'en') }
    end

    it 'uses the paid API host when the plan is not free' do
      service = described_class.new('paid', 'deepl-secret')
      stub_request(:post, 'https://api.deepl.com/v2/translate').to_return(
        status: 200,
        body: Oj.dump(translations: [{ text: 'Hello', detected_source_language: 'JA' }])
      )

      expect(service.translate(['こんにちは'], 'ja', 'en').first.text).to eq 'Hello'
    end

    it 'raises on rate limit, quota, unexpected status, and malformed JSON' do
      stub_request(:post, "#{base}/v2/translate").to_return(status: 429)
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::TooManyRequestsError)

      stub_request(:post, "#{base}/v2/translate").to_return(status: 456)
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::QuotaExceededError)

      stub_request(:post, "#{base}/v2/translate").to_return(status: 500, body: 'nope')
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)

      stub_request(:post, "#{base}/v2/translate").to_return(status: 200, body: 'not-json')
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)
    end
  end

  describe '#languages' do
    it 'normalizes codes and keeps generic en and pt targets' do
      stub_request(:get, "#{base}/v2/languages?type=source").to_return(
        status: 200,
        body: Oj.dump([{ 'language' => 'EN-US' }, { 'language' => 'PT-BR' }, { 'language' => 'JA' }])
      )
      stub_request(:get, "#{base}/v2/languages?type=target").to_return(
        status: 200,
        body: Oj.dump([{ 'language' => 'EN-US' }, { 'language' => 'JA' }])
      )

      languages = subject.languages

      expect(languages['ja']).to include('en', 'pt', 'en-US')
      expect(languages['ja']).not_to include('ja')
      expect(languages[nil]).to include('en', 'pt')
    end
  end
end
