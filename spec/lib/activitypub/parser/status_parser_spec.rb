# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::Parser::StatusParser do
  let(:public_collection) { 'https://www.w3.org/ns/activitystreams#Public' }

  describe '#uri' do
    it 'returns the object id' do
      parser = described_class.new('id' => 'https://example.com/users/alice/statuses/1')

      expect(parser.uri).to eq 'https://example.com/users/alice/statuses/1'
    end

    it 'reads the id from a wrapped object' do
      parser = described_class.new('object' => { 'id' => 'https://example.com/users/alice/statuses/2' })

      expect(parser.uri).to eq 'https://example.com/users/alice/statuses/2'
    end

    it 'unwraps a bear URI to its u parameter' do
      parser = described_class.new('id' => 'bear:?t=token&u=https%3A%2F%2Fexample.com%2Fusers%2Falice%2Fstatuses%2F3')

      expect(parser.uri).to eq 'https://example.com/users/alice/statuses/3'
    end

    it 'keeps a bear URI that Addressable rejects' do
      id = 'bear://foo\bar'
      parser = described_class.new('id' => id)

      expect(parser.uri).to eq id
    end
  end

  describe 'text fields' do
    it 'prefers content, summary, and name over their language maps' do
      parser = described_class.new(
        'content' => '<p>content</p>',
        'contentMap' => { 'en' => '<p>mapped</p>' },
        'summary' => 'summary',
        'summaryMap' => { 'en' => 'mapped summary' },
        'name' => 'name',
        'nameMap' => { 'en' => 'mapped name' }
      )

      expect(parser.text).to eq '<p>content</p>'
      expect(parser.spoiler_text).to eq 'summary'
      expect(parser.title).to eq 'name'
    end

    it 'falls back to the first language map value' do
      parser = described_class.new(
        'contentMap' => { 'fr' => '<p>bonjour</p>' },
        'summaryMap' => { 'fr' => 'avertissement' },
        'nameMap' => { 'fr' => 'titre' }
      )

      expect(parser.text).to eq '<p>bonjour</p>'
      expect(parser.spoiler_text).to eq 'avertissement'
      expect(parser.title).to eq 'titre'
    end
  end

  describe 'timestamps' do
    it 'parses published and updated' do
      parser = described_class.new(
        'published' => '2021-09-08T22:39:25Z',
        'updated' => '2021-09-09T01:02:03Z'
      )

      expect(parser.created_at).to eq '2021-09-08T22:39:25Z'.to_datetime
      expect(parser.edited_at).to eq '2021-09-09T01:02:03Z'.to_datetime
    end

    it 'returns nil for unparseable timestamps' do
      parser = described_class.new('published' => 'not-a-date', 'updated' => 'also-not')

      expect(parser.created_at).to be_nil
      expect(parser.edited_at).to be_nil
    end
  end

  describe '#reply' do
    it 'is true when inReplyTo is present' do
      expect(described_class.new('inReplyTo' => 'https://example.com/statuses/1').reply).to be true
      expect(described_class.new({}).reply).to be false
    end
  end

  describe '#sensitive' do
    it 'returns the sensitive value' do
      expect(described_class.new('sensitive' => true).sensitive).to be true
      expect(described_class.new({}).sensitive).to be_nil
    end
  end

  describe '#visibility' do
    it 'is public when to includes the public collection' do
      parser = described_class.new('to' => [{ 'id' => public_collection }])

      expect(parser.visibility).to eq :public
    end

    it 'is unlisted when cc includes the public collection' do
      parser = described_class.new('to' => ['https://example.com/followers'], 'cc' => [public_collection])

      expect(parser.visibility).to eq :unlisted
    end

    it 'is private when to includes the followers collection' do
      followers = 'https://example.com/users/alice/followers'
      parser = described_class.new({ 'to' => [followers] }, followers_collection: followers)

      expect(parser.visibility).to eq :private
    end

    it 'is direct otherwise' do
      parser = described_class.new('to' => ['https://example.com/users/bob'])

      expect(parser.visibility).to eq :direct
    end
  end

  describe '#language' do
    it 'uses contentMap, then nameMap, then summaryMap' do
      expect(described_class.new('contentMap' => { 'ja' => '本文' }, 'nameMap' => { 'en' => 'title' }).language).to eq 'ja'
      expect(described_class.new('nameMap' => { 'en' => 'title' }).language).to eq 'en'
      expect(described_class.new('summaryMap' => { 'de' => 'warnung' }).language).to eq 'de'
      expect(described_class.new('content' => 'plain').language).to be_nil
    end
  end
end
