# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TranslationService::LibreTranslate do
  subject { described_class.new('http://translate.local', 'optional-key') }

  describe '#translate' do
    it 'returns translated text and a detected source language' do
      stub_request(:post, 'http://translate.local/translate').to_return(
        status: 200,
        body: Oj.dump(translatedText: ['Hello'], detectedLanguage: [{ language: 'ja' }])
      )

      result = subject.translate(['こんにちは'], nil, 'en')

      expect(result.first.text).to eq 'Hello'
      expect(result.first.detected_source_language).to eq 'ja'
      expect(result.first.provider).to eq 'LibreTranslate'
    end

    it 'raises on rate limit, quota, unexpected status, and malformed JSON' do
      stub_request(:post, 'http://translate.local/translate').to_return(status: 429)
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::TooManyRequestsError)

      stub_request(:post, 'http://translate.local/translate').to_return(status: 403)
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::QuotaExceededError)

      stub_request(:post, 'http://translate.local/translate').to_return(status: 500, body: 'nope')
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)

      stub_request(:post, 'http://translate.local/translate').to_return(status: 200, body: '{')
      expect { subject.translate(['a'], 'ja', 'en') }.to raise_error(TranslationService::UnexpectedResponseError)
    end
  end

  describe '#languages' do
    it 'maps targets and exposes undetermined source languages under nil' do
      stub_request(:get, 'http://translate.local/languages').to_return(
        status: 200,
        body: Oj.dump([
          { code: 'ja', targets: %w(en ja) },
          { code: 'en', targets: %w(ja en) },
        ])
      )

      languages = subject.languages

      expect(languages['ja']).to eq ['en']
      expect(languages[nil]).to eq %w(en ja)
    end
  end
end
