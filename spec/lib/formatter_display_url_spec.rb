# frozen_string_literal: true

require 'rails_helper'

# The display representation of a URL: what link text shows, and what filters and
# keyword subscriptions match against besides the canonical percent-encoded form.
# It is never URL identity, so href and every other canonical form stay encoded.
RSpec.describe Formatter, '#display_url' do
  subject(:formatter) { described_class.instance }

  describe 'decoding' do
    it 'leaves a plain ASCII URL untouched' do
      expect(formatter.display_url('https://example.com/article?page=2')).to eq 'https://example.com/article?page=2'
    end

    it 'decodes a percent-encoded path' do
      expect(formatter.display_url('https://example.com/%E6%9D%B1%E4%BA%AC/page')).to eq 'https://example.com/東京/page'
    end

    it 'decodes a percent-encoded query value' do
      expect(formatter.display_url('https://example.com/search?q=%E6%9D%B1%E4%BA%AC')).to eq 'https://example.com/search?q=東京'
    end

    it 'decodes a percent-encoded fragment' do
      expect(formatter.display_url('https://example.com/page#%E6%9D%B1%E4%BA%AC')).to eq 'https://example.com/page#東京'
    end

    it 'decodes a percent-encoded emoji' do
      expect(formatter.display_url('https://example.com/%F0%9F%98%80')).to eq 'https://example.com/😀'
    end


    it 'decodes reserved punctuation, which is display material rather than URL structure' do
      expect(formatter.display_url('https://example.com/a%2Fb%3Fc%23d')).to eq 'https://example.com/a/b?c#d'
      expect(formatter.display_url('https://example.com/%7Bfoo%7D')).to eq 'https://example.com/{foo}'
    end

    it 'decodes exactly once' do
      expect(formatter.display_url('https://example.com/a%252Fb')).to eq 'https://example.com/a%2Fb'
      expect(formatter.display_url('https://example.com/%2540name')).to eq 'https://example.com/%40name'
    end
  end

  describe 'fallback to the canonical form' do
    it 'returns the input for a URL Addressable cannot parse' do
      ['http://', ':::::', 'https://ex ample.com/#[]'].each do |url|
        expect(formatter.display_url(url)).to eq url
      end
    end

    it 'returns the input when decoding produces bytes that are not valid UTF-8' do
      expect(formatter.display_url('https://example.com/%FF')).to eq 'https://example.com/%FF'
      expect(formatter.display_url('https://example.com/%E6%9D')).to eq 'https://example.com/%E6%9D'
    end

    it 'returns the input when the input itself is not valid UTF-8' do
      url = "https://example.com/\xFF".dup.force_encoding(Encoding::UTF_8)

      expect(formatter.display_url(url)).to eq url
    end


    it 'returns the input when decoding produces a control character' do
      {
        '%00' => 'NUL, the KeywordSubscribe segment separator',
        '%01' => 'the KeywordSubscribe hashtag marker',
        '%02' => 'the KeywordSubscribe URL marker',
        '%0D' => 'CR',
        '%0A' => 'LF',
        '%7F' => 'DEL',
        '%C2%85' => 'a C1 control',
      }.each_key do |sequence|
        url = "https://example.com/#{sequence}"

        expect(formatter.display_url(url)).to eq url
      end
    end

    it 'never raises and always returns a String' do
      [nil, '', 'not a url', 'https://example.com/%', "\xFF".dup.force_encoding(Encoding::UTF_8)].each do |url|
        expect(formatter.display_url(url)).to be_a String
      end
    end

    it 'does not mutate a frozen argument' do
      url = 'https://example.com/%E6%9D%B1%E4%BA%AC'

      expect(formatter.display_url(url)).to eq 'https://example.com/東京'
      expect(url).to eq 'https://example.com/%E6%9D%B1%E4%BA%AC'
    end
  end


  # The link keeps the canonical URL as its identity and shows the display form,
  # which is the behavior link_html always had for valid UTF-8 URLs.
  describe 'formatted links' do
    it 'keeps the encoded URL as href and shows the decoded URL as link text' do
      html = formatter.linkify('look https://example.com/%E6%9D%B1%E4%BA%AC/page now')

      expect(html).to include 'href="https://example.com/%E6%9D%B1%E4%BA%AC/page"'
      expect(html).to include '<span class="">example.com/東京/page</span>'
    end

    it 'shows a once-decoded URL as link text' do
      html = formatter.linkify('look https://example.com/a%252Fb now')

      expect(html).to include 'href="https://example.com/a%252Fb"'
      expect(html).to include '<span class="">example.com/a%2Fb</span>'
    end

    it 'shows the encoded URL as link text when decoding is refused' do
      html = formatter.linkify('look https://example.com/%FF now')

      expect(html).to include 'href="https://example.com/%FF"'
      expect(html).to include '<span class="">example.com/%FF</span>'
    end

    it 'keeps an ordinary ASCII link unchanged' do
      html = formatter.linkify('look https://example.com/article now')

      expect(html).to include 'href="https://example.com/article"'
      expect(html).to include '<span class="">example.com/article</span>'
    end
  end
end
