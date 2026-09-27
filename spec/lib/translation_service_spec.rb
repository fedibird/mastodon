# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TranslationService do
  around do |example|
    ClimateControl.modify(DEEPL_API_KEY: nil, DEEPL_PLAN: nil, LIBRE_TRANSLATE_ENDPOINT: nil, LIBRE_TRANSLATE_API_KEY: nil, LIBRE_TRANSLATE_ALLOW_PRIVATE: nil) do
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

  describe '.private_content_allowed?' do
    it 'is false when no provider is configured' do
      expect(described_class.private_content_allowed?).to be false
    end

    it 'is false for LibreTranslate unless the flag is exactly true' do
      [nil, '', 'false', 'abc', 'TRUE', 'True', '1', 'yes', 'on'].each do |flag|
        ClimateControl.modify(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: flag) do
          backend = described_class.configured

          expect(backend).to be_a(TranslationService::LibreTranslate)
          expect(backend.private_content_allowed?).to be false
          expect(described_class.private_content_allowed?).to be false
        end
      end
    end

    it 'is true when LibreTranslate is selected and the flag is exactly true' do
      ClimateControl.modify(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        backend = described_class.configured

        expect(backend).to be_a(TranslationService::LibreTranslate)
        expect(backend.private_content_allowed?).to be true
        expect(described_class.private_content_allowed?).to be true
      end
    end

    it 'is false for DeepL even when the LibreTranslate flag is true' do
      ClimateControl.modify(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        backend = described_class.configured

        expect(backend).to be_a(TranslationService::DeepL)
        expect(backend.private_content_allowed?).to be false
        expect(described_class.private_content_allowed?).to be false
        expect(TranslationService::DeepL.new('free', 'deepl-secret').private_content_allowed?).to be false
      end
    end

    it 'keeps DeepL selected and refuses private content when both providers are configured' do
      ClimateControl.modify(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true') do
        backend = described_class.configured

        expect(backend).to be_a(TranslationService::DeepL)
        expect(described_class.private_content_allowed?).to be false
      end
    end
  end

  describe '.timeout' do
    it 'does not override HTTP timeouts when unset' do
      ClimateControl.modify(TRANSLATION_TIMEOUT: nil) do
        expect(described_class.timeout).to be_nil
        expect(described_class.timeout_options).to be_nil
      end
    end

    it 'reads a positive integer from TRANSLATION_TIMEOUT' do
      ClimateControl.modify(TRANSLATION_TIMEOUT: '30') do
        expect(described_class.timeout).to eq 30
        expect(described_class.timeout_options).to eq(read_timeout: 30, read_deadline: 30)
      end
    end

    it 'ignores blank, non-numeric, zero, and negative values' do
      ['', 'abc', '0', '-1'].each do |value|
        ClimateControl.modify(TRANSLATION_TIMEOUT: value) do
          expect(described_class.timeout).to be_nil
          expect(described_class.timeout_options).to be_nil
        end
      end
    end
  end
end
