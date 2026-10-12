# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LanguagesHelper do
  it 'autoloads supported locales including Japanese' do
    expect(described_class::SUPPORTED_LOCALES[:ja]).to eq ['Japanese', '日本語']
  end

  describe '#valid_locale?' do
    it 'accepts base codes and the supported Chinese variants as exact strings' do
      %w(ja en de zh zh-CN zh-TW zh-HK zh-YUE).each do |code|
        expect(helper.valid_locale?(code)).to be(true), code
      end
    end

    it 'rejects an unsupported regional tag, an unknown code, a blank string, and nil' do
      ['ja-JP', 'invalid', '', nil].each do |code|
        expect(helper.valid_locale?(code)).to be(false), code.inspect
      end
    end
  end
end
