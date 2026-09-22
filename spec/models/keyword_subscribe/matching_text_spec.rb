# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KeywordSubscribe::MatchingText do
  let(:author) { Fabricate(:account, domain: nil, username: 'author') }

  def status_with(text, tags: [])
    status = Fabricate(:status, account: author, text: text)
    tags.each { |name| status.tags << Fabricate(:tag, name: name) }
    status
  end

  def text_for(status, match_hashtags: false, match_urls: false)
    described_class.new(status: status).text_for(match_hashtags: match_hashtags, match_urls: match_urls)
  end

  describe '.wrap' do
    it 'returns the same object for a prepared text' do
      prepared = described_class.new(body: 'hello')

      expect(described_class.wrap(prepared)).to be prepared
    end

    it 'treats a String as the body' do
      prepared = described_class.wrap('hello #tag')

      expect(prepared.text_for(match_hashtags: true, match_urls: true)).to eq 'hello #tag'
      expect(prepared.text_for(match_hashtags: false, match_urls: false)).to eq "hello #{described_class::SEPARATOR}"
    end
  end

  describe '#text_for' do
    it 'masks visible hashtag spans while match_hashtags is off' do
      status = status_with('hello #fediverse world', tags: %w(fediverse))

      expect(text_for(status)).to eq status.searchable_text.sub('#fediverse', described_class::SEPARATOR)
    end

    it 'keeps visible hashtags and appends every associated tag with match_hashtags on' do
      status = status_with('hello #fediverse world', tags: %w(fediverse hidden))

      expect(text_for(status, match_hashtags: true).split(described_class::SEPARATOR)).to eq [status.searchable_text, '#fediverse', '#hidden']
    end

    it 'appends nothing but the body while match_urls is off' do
      status = status_with('look https://example.com/pathword')

      expect(text_for(status)).to eq status.searchable_text
      expect(text_for(status)).not_to include 'example.com'
    end

    it 'appends Status#filterable_urls with match_urls on' do
      status = status_with('look https://example.com/pathword')

      expect(text_for(status, match_urls: true).split(described_class::SEPARATOR)).to eq [status.searchable_text, 'https://example.com/pathword']
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
