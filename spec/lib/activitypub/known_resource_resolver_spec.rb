# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::KnownResourceResolver do
  describe '#status' do
    let(:account) { Fabricate(:account, domain: 'remote.test', username: 'bob') }

    it 'resolves an exact ActivityPub id even when its display URL points elsewhere' do
      status = Fabricate(:status, account: account, uri: 'https://remote.test/objects/a1', url: 'https://publisher.test/articles/1')

      expect(described_class.new(status.uri).status).to eq(status)
    end

    it 'chooses the canonical id even if another server claims the same URL' do
      url = 'https://publisher.test/objects/canonical'
      Fabricate(:status, account: account, uri: 'https://remote.test/objects/alias', url: url)
      publisher = Fabricate(:account, domain: 'publisher.test', username: 'author')
      canonical = Fabricate(:status, account: publisher, uri: url, url: url)

      expect(described_class.new(url).status).to eq(canonical)
    end

    it 'does not mistake an aggregator claim on a third-party article for the article itself' do
      Fabricate(:status, account: account, uri: 'https://remote.test/objects/a2', url: 'https://publisher.test/articles/2')

      expect(described_class.new('https://publisher.test/articles/2').status).to be_nil
    end

    it 'does not choose arbitrarily when two aggregators claim the same external URL' do
      url = 'https://publisher.test/articles/shared'
      Fabricate(:status, account: account, uri: 'https://remote.test/objects/shared-a', url: url)
      other = Fabricate(:account, domain: 'other.test', username: 'relay')
      Fabricate(:status, account: other, uri: 'https://other.test/objects/shared-b', url: url)

      expect(described_class.new(url).status).to be_nil
    end

    it 'resolves a Mastodon-style public URL via the indexed uri and verifies the original URL' do
      url = 'https://remote.test/@bob/123'
      status = Fabricate(:status, account: account, uri: 'https://remote.test/users/bob/statuses/123', url: url)

      statements = []
      subscriber = ->(_event, _start, _finish, _id, payload) do
        statements << payload[:sql] if payload[:sql].include?('SELECT') && payload[:sql].include?('FROM "statuses"')
      end

      resolved = nil
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        resolved = described_class.new(url).status
      end

      expect(resolved).to eq(status)
      expect(statements).not_to be_empty
      expect(statements).to all(include('"statuses"."uri"'))
    end

    it 'accepts the /statuses/ variant of a public URL' do
      url = 'https://remote.test/@bob/statuses/abc123'
      status = Fabricate(:status, account: account, uri: 'https://remote.test/users/bob/statuses/abc123', url: url)

      expect(described_class.new(url).status).to eq(status)
    end

    it 'rejects a public URL whose candidate URI exists but whose recorded URL differs' do
      Fabricate(:status, account: account, uri: 'https://remote.test/users/bob/statuses/123', url: 'https://remote.test/other/123')

      expect(described_class.new('https://remote.test/@bob/123').status).to be_nil
    end

    it 'does not infer identities from a URL containing a query, fragment, or userinfo' do
      Fabricate(:status, account: account, uri: 'https://remote.test/users/bob/statuses/123', url: 'https://remote.test/@bob/123?ref=1')

      expect(described_class.new('https://remote.test/@bob/123?ref=1').status).to be_nil
      expect(described_class.new('https://remote.test/@bob/123#reply').status).to be_nil
      expect(described_class.new('https://user@remote.test/@bob/123').status).to be_nil
    end

    it 'does not turn an unrelated URL into a status URL' do
      expect(described_class.new('https://publisher.test/articles/123').status).to be_nil
    end

    it 'returns nil for nil and invalid URLs' do
      expect(described_class.new(nil).status).to be_nil
      expect(described_class.new('https://[invalid').status).to be_nil
    end
  end

  describe '#account' do
    it 'resolves an exact actor id even if the profile URL is external' do
      account = Fabricate(:account, domain: 'remote.test', username: 'alice', uri: 'https://remote.test/users/alice', url: 'https://publisher.test/alice')

      expect(described_class.new(account.uri).account).to eq(account)
    end

    it 'prefers an exact actor id over a competing account profile alias' do
      url = 'https://remote.test/actors/author'
      Fabricate(:account, domain: 'remote.test', username: 'relay', uri: 'https://remote.test/users/relay', url: url)
      canonical = Fabricate(:account, domain: 'remote.test', username: 'author', uri: url, url: url)

      expect(described_class.new(url).account).to eq(canonical)
    end

    it 'does not resolve a third-party profile URL claimed by an actor' do
      Fabricate(:account, domain: 'remote.test', username: 'alice', uri: 'https://remote.test/users/alice', url: 'https://publisher.test/alice')

      expect(described_class.new('https://publisher.test/alice').account).to be_nil
    end

    it 'still resolves a unique same-origin profile URL' do
      account = Fabricate(:account, domain: 'remote.test', username: 'alice', uri: 'https://remote.test/users/alice', url: 'https://remote.test/@alice')

      expect(described_class.new('https://remote.test/@alice').account).to eq(account)
    end

    it 'rejects an ambiguous same-origin URL shared by two accounts' do
      url = 'https://remote.test/@shared'
      Fabricate(:account, domain: 'remote.test', username: 'alice', uri: 'https://remote.test/users/alice', url: url)
      Fabricate(:account, domain: 'remote.test', username: 'bob', uri: 'https://remote.test/users/bob', url: url)

      expect(described_class.new(url).account).to be_nil
    end

    it 'does not treat a different scheme or port as the same origin' do
      Fabricate(:account, domain: 'remote.test', username: 'alice', uri: 'https://remote.test/users/alice', url: 'http://remote.test/@alice')
      Fabricate(:account, domain: 'remote.test', username: 'bob', uri: 'https://remote.test/users/bob', url: 'https://remote.test:8443/@bob')

      expect(described_class.new('http://remote.test/@alice').account).to be_nil
      expect(described_class.new('https://remote.test:8443/@bob').account).to be_nil
    end
  end
end
