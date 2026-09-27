# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TranslationService do
  around do |example|
    ClimateControl.modify(DEEPL_API_KEY: nil, DEEPL_PLAN: nil, LIBRE_TRANSLATE_ENDPOINT: nil, LIBRE_TRANSLATE_API_KEY: nil) do
      example.run
    end
  end

  describe '.configured?' do
    it 'is false when no provider is configured' do
      expect(described_class.configured?).to be false
    end

    it 'is true for DeepL' do
      ClimateControl.modify(DEEPL_API_KEY: 'deepl-secret') do
        expect(described_class.configured?).to be true
        expect(described_class.configured).to be_a(TranslationService::DeepL)
      end
    end

    it 'is true for LibreTranslate' do
      ClimateControl.modify(LIBRE_TRANSLATE_ENDPOINT: 'http://translate.local') do
        expect(described_class.configured).to be_a(TranslationService::LibreTranslate)
      end
    end

    it 'prefers DeepL when both providers are configured' do
      ClimateControl.modify(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ENDPOINT: 'http://translate.local') do
        expect(described_class.configured).to be_a(TranslationService::DeepL)
      end
    end

    it 'raises when configured is called without a provider' do
      expect { described_class.configured }.to raise_error(TranslationService::NotConfiguredError)
    end
  end

  describe '.timeout' do
    it 'uses the normal HTTP read timeout when unset' do
      ClimateControl.modify(TRANSLATION_TIMEOUT: nil) do
        expect(described_class.timeout).to eq 10
        expect(described_class.timeout_options).to eq(read_timeout: 10, read_deadline: 10)
      end
    end

    it 'reads a positive integer from TRANSLATION_TIMEOUT' do
      ClimateControl.modify(TRANSLATION_TIMEOUT: '30') do
        expect(described_class.timeout).to eq 30
        expect(described_class.timeout_options).to eq(read_timeout: 30, read_deadline: 30)
      end
    end

    it 'falls back to the default for blank, non-numeric, zero, and negative values' do
      ['', 'abc', '0', '-1'].each do |value|
        ClimateControl.modify(TRANSLATION_TIMEOUT: value) do
          expect(described_class.timeout).to eq 10
        end
      end
    end
  end
end
