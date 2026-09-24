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
end
