# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KeywordSubscribe::MatchingText do # rubocop:disable Metrics/BlockLength
  let(:author) { Fabricate(:account, domain: nil, username: 'author') }

  def status_with(text, tags: [])
    status = Fabricate(:status, account: author, text: text)
    tags.each { |name| status.tags << Fabricate(:tag, name: name) }
    status
  end

  def text_for(status, match_hashtags: false, match_urls: false)
    described_class.new(status: status).text_for(match_hashtags: match_hashtags, match_urls: match_urls)
  end

  def segments(text)
    text.split(described_class::SEPARATOR)
  end

  describe '.wrap' do
    it 'returns the same object for a prepared text' do
      prepared = described_class.new(body: 'hello')

      expect(described_class.wrap(prepared)).to be prepared
    end

    it 'treats a String as the body' do
      prepared = described_class.wrap('hello #tag')

      expect(prepared.text_for(match_hashtags: true, match_urls: true)).to eq "hello #tag#{described_class::SEPARATOR}#{described_class::HASHTAG_MARKER}#tag"
      expect(prepared.text_for(match_hashtags: false, match_urls: false)).to eq "hello #{described_class::SEPARATOR}"
    end
  end

  describe '#text_for' do
    it 'masks visible hashtag spans while match_hashtags is off' do
      status = status_with('hello #fediverse world', tags: %w(fediverse))

      expect(text_for(status)).to eq status.searchable_text.sub('#fediverse', described_class::SEPARATOR)
    end

    it 'keeps visible hashtags and appends every tag the status carries with match_hashtags on' do
      status = status_with('hello #fediverse world', tags: %w(fediverse hidden))
      marker = described_class::HASHTAG_MARKER

      expect(segments(text_for(status, match_hashtags: true))).to eq [status.searchable_text, "#{marker}#fediverse", "#{marker}#hidden"]
    end

    it 'appends a token for a visible hashtag that carries no tag record' do
      status = status_with('hello #fediverse world')
      marker = described_class::HASHTAG_MARKER

      expect(segments(text_for(status, match_hashtags: true))).to eq [status.searchable_text, "#{marker}#fediverse"]
    end

    it 'appends nothing but the body while match_urls is off' do
      status = status_with('look https://example.com/pathword')

      expect(segments(text_for(status)).size).to eq 1
      expect(text_for(status)).not_to include 'example.com'
    end

    it 'appends Status#filterable_urls with match_urls on' do
      status = status_with('look https://example.com/pathword')
      marker = described_class::URL_MARKER

      expect(segments(text_for(status, match_urls: true))).to eq [status.searchable_text, "#{marker}https://example.com/pathword"]
    end

    # Status#searchable_text only removes the URLs Status itself discovered, so a
    # URL written in a form that normalizes differently survives there.
    it 'masks a URL that Status left in the body, whichever way match_urls is set' do
      status = status_with('look https://example.com/東京/page')
      marker = described_class::URL_MARKER

      expect(status.searchable_text).to include 'https://example.com/東京/page'
      expect(text_for(status)).not_to include 'example.com'
      expect(text_for(status)).not_to include '東京'
      expect(segments(text_for(status, match_urls: true)).last(2)).to eq [
        "#{marker}https://example.com/%E6%9D%B1%E4%BA%AC/page",
        "#{marker}https://example.com/東京/page",
      ]
    end

    # Status#filterable_urls carries the canonical URL and the human-readable form
    # Formatter shows as link text, each in its own segment.
    it 'appends the display form of a percent-encoded URL as its own segment' do
      status = status_with('look https://example.com/%E6%9D%B1%E4%BA%AC/page')
      marker = described_class::URL_MARKER

      expect(segments(text_for(status, match_urls: true))).to eq [
        status.searchable_text,
        "#{marker}https://example.com/%E6%9D%B1%E4%BA%AC/page",
        "#{marker}https://example.com/東京/page",
      ]
    end

    it 'appends no display segment for a URL whose decoded form would carry a control character' do
      status = status_with('look https://example.com/%00/page')
      marker = described_class::URL_MARKER

      expect(segments(text_for(status, match_urls: true))).to eq [
        status.searchable_text,
        "#{marker}https://example.com/%00/page",
      ]
    end

    it 'leaves protocol-less text that Mastodon does not treat as a URL' do
      status = status_with('mail example.com for details')

      expect(text_for(status)).to include 'example.com'
    end

    it 'keeps a URL fragment in URL material even while hashtags are masked' do
      status = status_with('see https://example.com/#foo now #foo', tags: %w(foo))

      prepared = text_for(status, match_urls: true)

      expect(prepared).to include 'https://example.com/#foo'
      expect(prepared).not_to include 'now #foo'
    end

    it 'prepares each combination once and caches it' do
      status = status_with('look https://example.com/pathword', tags: %w(fediverse))
      prepared = described_class.new(status: status)

      allow(status).to receive(:filterable_urls).and_call_original

      3.times { prepared.text_for(match_hashtags: true, match_urls: true) }

      expect(status).to have_received(:filterable_urls).once
    end

    it 'does not load tags or URLs for the default combination' do
      status = status_with('a bodyword here', tags: %w(fediverse))
      prepared = described_class.new(status: status)

      allow(status).to receive(:filterable_urls).and_call_original
      allow(status).to receive(:tags).and_call_original

      prepared.text_for(match_hashtags: false, match_urls: false)

      expect(status).not_to have_received(:filterable_urls)
      expect(status).not_to have_received(:tags)
    end
  end
end
