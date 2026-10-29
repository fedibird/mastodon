# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::CanonicalURL do
  def normalize(value, **options)
    described_class.normalize!(value, **options)
  end

  def rejection(value, **options)
    normalize(value, **options)
    nil
  rescue ExternalBridge::Error => e
    e.code
  end

  describe 'default mode' do
    it 'keeps the existing format canonical key, case folding, and nested percent-encoding' do
      expect(normalize('https://feeds.example/listed.xml?FORMAT=RSS')).to eq 'https://feeds.example/listed.xml?format=rss'
      expect(normalize('https://feeds.example/encoded.xml?%2566ormat=%2572ss')).to eq 'https://feeds.example/encoded.xml?format=rss'
      expect(normalize('HTTPS://Feeds.EXAMPLE:443/listed.xml?format=atom#frag')).to eq 'https://feeds.example/listed.xml?format=atom'
    end

    it 'does not accept the feed-only selection parameters' do
      [
        'https://feeds.example/listed.xml?format=rss2',
        'https://feeds.example/listed.xml?format=rss_200',
        'https://feeds.example/listed.xml?format=rss_200_enc',
        'https://feeds.example/listed.xml?feed=rss2',
        'https://feeds.example/listed.xml?alt=rss',
        'https://feeds.example/listed.xml?exclude_body=1',
        'https://feeds.example/listed.xml?include_scraps=0',
        'https://feeds.example/listed.xml?all=1',
        'https://feeds.example/listed.xml?order=created',
        'https://feeds.example/listed.xml?period=weekly',
        'https://feeds.example/listed.xml?format=rss&exclude_body=1',
      ].each do |url|
        expect(rejection(url)).to eq('authenticated_source_rejected'), url
      end
    end
  end

  describe 'feed mode' do
    base = 'https://feeds.example/news'

    {
      'format' => %w(rss atom xml feed rss2 rss_200 rss_200_enc),
      'feed' => %w(rss2),
      'alt' => %w(rss),
      'exclude_body' => %w(0 1),
      'include_scraps' => %w(0 1),
      'all' => %w(0 1),
      'order' => %w(created),
      'period' => %w(weekly),
    }.each do |name, values|
      values.each do |value|
        it "accepts #{name}=#{value}" do
          expect(normalize("#{base}?#{name}=#{value}", feed: true)).to eq "#{base}?#{name}=#{value}"
        end
      end
    end

    it 'keeps a safe combination and does not rewrite pair order' do
      forward = "#{base}?format=rss_200&exclude_body=1"
      reverse = "#{base}?exclude_body=1&format=rss_200"
      expect(normalize(forward, feed: true)).to eq forward
      expect(normalize(reverse, feed: true)).to eq reverse
      expect(normalize(forward, feed: true)).not_to eq normalize(reverse, feed: true)
    end

    it 'canonicalizes case, separators, and nested encoding without moving pair boundaries again' do
      raw = 'HTTPS://Feeds.EXAMPLE:443/News.xml?FORMAT=%2572ss_200;Exclude_Body=%31#skip'
      canonical = 'https://feeds.example/News.xml?format=rss_200&exclude_body=1'
      expect(normalize(raw, feed: true)).to eq canonical
      expect(normalize(canonical, feed: true)).to eq canonical
    end

    it 'accepts six pairs and rejects a seventh' do
      six = %w(format=rss feed=rss2 alt=rss exclude_body=0 include_scraps=1 all=0)
      expect(normalize("#{base}?#{six.join('&')}", feed: true)).to eq "#{base}?#{six.join('&')}"
      expect(rejection("#{base}?#{six.join('&')}&order=created", feed: true)).to eq 'authenticated_source_rejected'
    end

    it 'rejects values outside the finite set, including later identifier parameters' do
      %w(
        format=rss3 format=daily feed=rss feed=atom alt=atom alt=rss2
        exclude_body=2 exclude_body=true include_scraps=yes all=2
        order=published period=daily period=WEEK
        tag=news channel=1 playlist=abc id=1 p=123 q=hello search=news
      ).each do |query|
        expect(rejection("#{base}?#{query}", feed: true)).to eq('authenticated_source_rejected'), query
      end
    end

    it 'rejects duplicate keys after case folding and percent-decoding' do
      [
        "#{base}?format=rss&format=atom",
        "#{base}?format=rss&FORMAT=rss",
        "#{base}?format=rss&%2566ormat=atom",
        "#{base}?Exclude_Body=1&exclude_body=0",
        "#{base}?%66ormat=rss&format=rss2",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects empty pairs, empty values, and spare separators' do
      [
        "#{base}?",
        "#{base}?format=",
        "#{base}?format",
        "#{base}?=rss",
        "#{base}?format=rss&",
        "#{base}?&format=rss",
        "#{base}?format=rss&&exclude_body=1",
        "#{base}?format=rss;",
        "#{base}?;exclude_body=1",
        "#{base}?format=rss&exclude_body=1&",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects encoded delimiters and control characters instead of splitting them into pairs' do
      [
        "#{base}?format=rss%26exclude_body%3D1",
        "#{base}?format=rss%3Bexclude_body%3D1",
        "#{base}?format=rss%3D2",
        "#{base}?format=rs%0as",
        "#{base}?exclude_body=1%00",
        "#{base}?%26exclude_body=1",
        "#{base}?format=%",
        "#{base}?format=%ZZ",
        "#{base}?format=%2",
        "#{base}?format=#{'a' * 80}",
      ].each do |url|
        expect(rejection(url, feed: true)).to eq('authenticated_source_rejected'), url
      end
    end

    it 'rejects a known key mixed with a credential or an unknown key' do
      %w(token key auth signature sig password secret access_token api_key category preview).each do |name|
        expect(rejection("#{base}?format=rss&#{name}=SECRET", feed: true)).to eq('authenticated_source_rejected'), name
      end
      expect(rejection("#{base}?format=rss2&channel=news", feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection("#{base}?exclude_body=1&playlist=abc", feed: true)).to eq 'authenticated_source_rejected'
    end

    it 'rejects userinfo, private literals, and non-http schemes before a query could be kept' do
      expect(rejection('https://user:pw@feeds.example/news?format=rss2', feed: true)).to eq 'authenticated_source_rejected'
      expect(rejection('http://127.0.0.1/news?format=rss', feed: true)).to eq 'private_address'
      expect(rejection('http://10.1.2.3/news?exclude_body=1', feed: true)).to eq 'private_address'
      expect(rejection('http://[::1]/news?period=weekly', feed: true)).to eq 'private_address'
      expect(rejection('ftp://feeds.example/news?format=rss', feed: true)).to eq 'unsupported_url'
      expect(rejection('javascript:alert(1)', feed: true)).to eq 'unsupported_url'
    end
  end

  describe 'other modes' do
    it 'does not gain the feed selection keys' do
      expect(normalize('https://cdn.example/i.png?format=rss2', asset: true)).to eq 'https://cdn.example/i.png?format=rss2'
      expect(rejection('https://cdn.example/i.png?exclude_body=1', asset: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://cdn.example/i.png?format=rss2&exclude_body=1', asset: true)).to eq 'authenticated_source_rejected'

      expect(normalize('https://feeds.example/watch?id=abc&format=rss', item: true)).to eq 'https://feeds.example/watch?id=abc&format=rss'
      expect(rejection('https://feeds.example/watch?format=rss2', item: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://feeds.example/watch?id=abc&exclude_body=1', item: true)).to eq 'authenticated_source_rejected'
      expect(rejection('https://feeds.example/watch?order=created', item: true)).to eq 'authenticated_source_rejected'
    end

    it 'keeps site links on the default rules' do
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site')).to eq 'https://example.com/site'
      expect(ExternalBridge::Presentation.normalize_url('https://feeds.example/listed.xml?format=rss')).to eq 'https://feeds.example/listed.xml?format=rss'
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?exclude_body=1')).to be_nil
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?format=rss2')).to be_nil
      expect(ExternalBridge::Presentation.normalize_url('https://example.com/site?format=rss&token=SECRET')).to be_nil
    end
  end
end
