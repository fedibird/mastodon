require 'rails_helper'

RSpec.describe EntityCache do
  let(:local_account)  { Fabricate(:account, domain: nil, username: 'alice') }
  let(:remote_account) { Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/') }

  describe '#emoji' do
    subject { EntityCache.instance.emoji(shortcodes, domain) }

    context 'called with an empty list of shortcodes' do
      let(:shortcodes) { [] }
      let(:domain)     { 'example.org' }

      it 'returns an empty array' do
        is_expected.to eq []
      end
    end
  end

  describe '#holding_status' do
    let(:aggregator) { Fabricate(:account, domain: 'aggregator.test', username: 'relay') }

    it 'does not resolve an article URL from an aggregator status.url claim' do
      url = 'https://publisher.test/articles/entity-cache-1'
      Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/a1', url: url)

      expect(described_class.instance.holding_status(url)).to be_nil
    end

    it 'ignores old cached URL aliases from before the identity policy changed' do
      url = 'https://publisher.test/articles/legacy-alias'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/old', url: url)
      Rails.cache.write(described_class.instance.to_key(:holding_status, url), status)

      expect(described_class.instance.holding_status(url)).to be_nil
    end

    it 'keeps distinct cache entries for case-sensitive URL paths' do
      url = 'https://aggregator.test/@relay/AbC123'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/users/relay/statuses/AbC123', url: url)

      expect(described_class.instance.holding_status(url)).to eq(status)
      expect(described_class.instance.holding_status('https://aggregator.test/@relay/abc123')).to be_nil
    end

    it 'can cache an independently discovered AP alternate after a negative lookup' do
      link = 'https://publisher.test/articles/with-alternate'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/discovered', url: 'https://aggregator.test/@relay/discovered')

      expect(described_class.instance.holding_status(link)).to be_nil
      described_class.instance.update_holding_status(link, status)
      expect(described_class.instance.holding_status(link)).to eq(status)
    end

    it 'lets an imported canonical AP id supersede an older verified alternate cache' do
      url = 'https://publisher.test/objects/newly-imported'
      cached = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/cached', url: url)
      described_class.instance.update_holding_status(url, cached)

      publisher = Fabricate(:account, domain: 'publisher.test', username: 'author')
      canonical = Fabricate(:status, account: publisher, uri: url, url: url)

      expect(described_class.instance.holding_status(url)).to eq(canonical)
    end

    it 'resolves the canonical AP URI regardless of the remote display URL' do
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/direct', url: 'https://publisher.test/articles/direct')

      expect(described_class.instance.holding_status(status.uri)).to eq(status)
    end
  end

  describe '#holding_account' do
    it 'does not resolve a third-party profile link claimed by a remote actor' do
      account = Fabricate(:account, domain: 'aggregator.test', username: 'relay', uri: 'https://aggregator.test/users/relay', url: 'https://publisher.test/profiles/relay')

      expect(described_class.instance.holding_account('https://publisher.test/profiles/relay')).to be_nil
      expect(described_class.instance.holding_account(account.uri)).to eq(account)
    end
  end
end
