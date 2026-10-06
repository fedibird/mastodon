# frozen_string_literal: true

require 'rails_helper'

describe Sanitize::Config do
  describe '::MASTODON_STRICT' do
    subject { Sanitize::Config::MASTODON_STRICT }

    it 'converts h1 to p strong' do
      expect(Sanitize.fragment('<h1>Foo</h1>', subject)).to eq '<p><strong>Foo</strong></p>'
    end

    it 'keeps ul' do
      expect(Sanitize.fragment('<p>Check out:</p><ul><li>Foo</li><li>Bar</li></ul>', subject)).to eq '<p>Check out:</p><ul><li>Foo</li><li>Bar</li></ul>'
    end

    it 'keeps start and reversed attributes of ol' do
      expect(Sanitize.fragment('<p>Check out:</p><ol start="3" reversed=""><li>Foo</li><li>Bar</li></ol>', subject)).to eq '<p>Check out:</p><ol start="3" reversed=""><li>Foo</li><li>Bar</li></ol>'
    end

    it 'keeps small elements' do
      expect(Sanitize.fragment('<p>Hello <small>#one</small></p>', subject)).to eq '<p>Hello <small>#one</small></p>'
    end

    it 'canonicalizes a Misskey trailing hashtag group before rel=tag is replaced' do
      html = <<~HTML
        <p>Hello <small>
          <a href="https://misskey.example/tags/one" rel="tag">#one</a>
          <a href="https://misskey.example/tags/two" rel="tag">#two</a>
        </small></p>
      HTML
      fragment = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject))
      wrapper = fragment.at_css('small')
      anchors = wrapper.css('a')

      expect(wrapper).to be_present
      expect(anchors.map { |anchor| anchor.text }).to eq ['#one', '#two']
      expect(anchors.map { |anchor| anchor['href'] }).to eq [
        'https://misskey.example/tags/one',
        'https://misskey.example/tags/two',
      ]
      anchors.each do |anchor|
        expect(anchor['class'].to_s.split).to eq %w(mention hashtag)
        expect(anchor['rel'].to_s.split).to eq %w(nofollow noopener noreferrer)
        expect(anchor['rel'].to_s.split).not_to include('tag')
      end
    end

    it 'keeps existing classes and does not mark an ordinary link as a hashtag' do
      html = <<~HTML
        <p><a class="u-url mention" href="https://misskey.example/tags/one" rel="tag">#one</a>
        <a href="https://example.com/post" rel="noopener">#not-a-tag</a>
        <a href="https://example.com/tags/two" rel="tag">two</a></p>
      HTML
      fragment = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject))
      anchors = fragment.css('a')

      expect(anchors[0]['class'].to_s.split).to eq %w(u-url mention hashtag)
      expect(anchors[1]['class'].to_s).not_to include('hashtag')
      expect(anchors[1]['class'].to_s).not_to include('mention')
      expect(anchors[2]['class'].to_s).not_to include('hashtag')
      expect(anchors[2]['class'].to_s).not_to include('mention')
    end

    it 'canonicalizes a Pixelfed hashtag anchor that uses class instead of rel=tag' do
      html = <<~HTML
        たぶんナラタケモドキ。<br /> <br />
        <a href="https://fedisnap.com/discover/tags/fedibird?src=hash" title="#fedibird" class="u-url hashtag" rel="external nofollow noopener">#fedibird</a>
      HTML
      fragment = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject))
      anchor = fragment.at_css('a')

      expect(anchor.text).to eq '#fedibird'
      expect(anchor['href']).to eq 'https://fedisnap.com/discover/tags/fedibird?src=hash'
      expect(anchor['class'].to_s.split).to contain_exactly('u-url', 'hashtag', 'mention')
      expect(anchor['rel'].to_s.split).to eq %w(nofollow noopener noreferrer)
      expect(anchor['target']).to eq '_blank'
      expect(anchor['title']).to be_nil
    end

    it 'canonicalizes a fullwidth hash when the anchor is already marked as a hashtag' do
      html = '<a href="https://example.com/tags/one" class="hashtag">＃one</a>'
      anchor = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject)).at_css('a')

      expect(anchor['class'].to_s.split).to contain_exactly('hashtag', 'mention')
    end

    it 'does not canonicalize a u-url link whose text merely starts with a hash' do
      html = '<a href="https://example.com/tags/not-a-tag" class="u-url">#not-a-tag</a>'
      anchor = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject)).at_css('a')

      expect(anchor.text).to eq '#not-a-tag'
      expect(anchor['class'].to_s.split).to eq %w(u-url)
    end

    it 'does not add mention when a hashtag class is not a hash-prefixed label' do
      html = '<a href="https://fedisnap.com/discover/tags/fedibird" class="hashtag">fedibird</a>'
      anchor = Nokogiri::HTML.fragment(Sanitize.fragment(html, subject)).at_css('a')

      expect(anchor.text).to eq 'fedibird'
      expect(anchor['class'].to_s.split).to eq %w(hashtag)
      expect(anchor['class'].to_s.split).not_to include('mention')
    end

    it 'does not canonicalize an ordinary link whose text starts with a hash' do
      expect(Sanitize.fragment('<a>#not-a-tag</a>', subject)).to eq '#not-a-tag'
      expect(Sanitize.fragment('<a href="https://example.com/">#not-a-tag</a>', subject)).to eq '<a href="https://example.com/" rel="nofollow noopener noreferrer" target="_blank">#not-a-tag</a>'
    end

    it 'keeps ruby tags' do
      expect(Sanitize.fragment('<p><ruby>明日 <rp>(</rp><rt>Ashita</rt><rp>)</rp></ruby></p>', subject)).to eq '<p><ruby>明日 <rp>(</rp><rt>Ashita</rt><rp>)</rp></ruby></p>'
    end

    it 'removes a without href' do
      expect(Sanitize.fragment('<a>Test</a>', subject)).to eq 'Test'
    end

    it 'removes a without href and only keeps text content' do
      expect(Sanitize.fragment('<a><span class="invisible">foo&amp;</span><span>Test</span></a>', subject)).to eq 'foo&amp;Test'
    end

    it 'removes a with unsupported scheme in href' do
      expect(Sanitize.fragment('<a href="foo://bar">Test</a>', subject)).to eq 'Test'
    end

    it 'keeps a with href' do
      expect(Sanitize.fragment('<a href="http://example.com">Test</a>', subject)).to eq '<a href="http://example.com" rel="nofollow noopener noreferrer" target="_blank">Test</a>'
    end

    it 'removes a with unparsable href' do
      expect(Sanitize.fragment('<a href=" https://google.fr">Test</a>', subject)).to eq 'Test'
    end

    it 'keeps a with supported scheme and no host' do
      expect(Sanitize.fragment('<a href="dweb:/a/foo">Test</a>', subject)).to eq '<a href="dweb:/a/foo" rel="nofollow noopener noreferrer" target="_blank">Test</a>'
    end
  end
end
