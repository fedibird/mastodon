# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe ExternalBridge::RSS::Presentation do
  describe '.for' do
    let(:resource) do
      ExternalResource.new(
        title: '旅行記 第3回',
        byline: 'Ada',
        canonical_url: 'https://example.com/posts/3',
        body: '本文です'
      )
    end

    it 'keeps the four display combinations independent' do
      off = described_class.for(resource, media_sensitive: false, cw_enabled: false)
      media = described_class.for(resource, media_sensitive: true, cw_enabled: false)
      cw = described_class.for(resource, media_sensitive: false, cw_enabled: true)
      both = described_class.for(resource, media_sensitive: true, cw_enabled: true)

      expect(off.spoiler_text).to eq('')
      expect(off.sensitive).to eq(false)
      expect(off.text).to include('旅行記 第3回')
      expect(off.text).to include('https://example.com/posts/3')
      expect(off.text).to include('本文です')

      expect(media.spoiler_text).to eq('')
      expect(media.text).to eq(off.text)
      expect(media.sensitive).to eq(true)

      expect(cw.spoiler_text).to eq('旅行記 第3回')
      expect(cw.text).not_to include('旅行記 第3回')
      expect(cw.text).to include('https://example.com/posts/3')
      expect(cw.text).to include('本文です')
      expect(cw.sensitive).to eq(false)

      expect(both.spoiler_text).to eq('旅行記 第3回')
      expect(both.text).to eq(cw.text)
      expect(both.sensitive).to eq(true)
    end

    it 'turns an empty or HTML title into plain warning text and still fits the length limit' do
      html = resource.dup
      html.title = "<b>旅行記 第3回</b>\n<script>alert(1)</script>"
      fields = described_class.for(html, media_sensitive: false, cw_enabled: true)
      expect(fields.spoiler_text).to eq('旅行記 第3回')
      expect(fields.spoiler_text).not_to include('<')
      expect(fields.spoiler_text).not_to include('alert')
      expect(fits(fields)).to eq(true)

      blank = resource.dup
      blank.title = " \u0000<br>\n"
      untitled = described_class.for(blank, media_sensitive: false, cw_enabled: true)
      expect(untitled.spoiler_text).to eq(I18n.t('external_bridge.untitled_article'))
      expect(untitled.text).to be_present
      expect(fits(untitled)).to eq(true)

      huge = resource.dup
      huge.title = '題' * 2_000
      huge.body = '本' * 5_000
      huge.canonical_url = "https://example.com/#{'c' * 400}"
      long = described_class.for(huge, media_sensitive: true, cw_enabled: true)
      expect(long.spoiler_text).not_to include("\n")
      expect(long.text.split("\n\n").first).not_to eq(long.spoiler_text)
      expect(fits(long)).to eq(true)

      emoji = resource.dup
      emoji.title = "家族#{'👨‍👩‍👧‍👦' * 200}"
      packed = described_class.for(emoji, media_sensitive: false, cw_enabled: true)
      expect(fits(packed)).to eq(true)
    end

    def fits(fields)
      status = Status.new(text: fields.text, spoiler_text: fields.spoiler_text, local: true)
      StatusLengthValidator.new({}).validate(status)
      status.errors[:text].empty?
    end
  end
end

# rubocop:enable Metrics/BlockLength
